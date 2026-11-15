"""
pyang plugin computing a fingerprint per oper component (see oper-components.txt) of what
pyangbind consumes to build its bindings, so that only the components whose fingerprint
changed need to be rebuilt.

  -f pybind-fp --pybind-components=<file>   JSON {"components": {<component>: <sha256>}}
     [--pybind-unclaimed-out=<file>]        also write the report of the state not claimed by
                                            any component (as --pybind-report-unclaimed of
                                            pybind-split does), from the same parse

The fingerprint is taken over the compiled schema (uses expanded, augments merged, deviations
applied), so that it changes whenever the component's bindings could change, whichever file
the change comes from (e.g. another module augmenting into the component's subtree). It covers:
  - the path down to each of the component's subtrees, with the list keys
  - every node in the subtrees, with all their substatements
  - the typedef chains of their types, and the type of the leaf a leafref points to
  - the identities derived from the base of their identityrefs, in any module

It covers more than pyangbind emits (e.g. config nodes and descriptions); that only causes a
rebuild that wasn't needed, never a missed one.
"""

import hashlib
import json
import optparse
import os
import sys

from pyang import plugin

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pybind_split import list_keys, report_unclaimed, resolve_path  # noqa: E402

# Expanded into i_children by pyang, so they are hashed through the nodes they create
EXPANDED_KEYWORDS = ("uses", "augment", "grouping")
SKIPPED_PARENTS = ("augment", "choice", "case", "uses", "grouping")


def pyang_plugin_init():
    plugin.register_plugin(PybindFingerprint())


def read_components(path):
    comps = {}
    with open(path) as fd:
        for line in fd:
            parts = line.split()
            if parts and not parts[0].startswith("#"):
                comps.setdefault(parts[0], []).append(parts[1])
    return comps


def stmt_ref(stmt):
    return (stmt.i_module.arg if getattr(stmt, "i_module", None) else "", stmt.keyword, stmt.arg or "")


class PybindFingerprint(plugin.PyangPlugin):
    def add_output_format(self, fmts):
        self.multiple_modules = True
        fmts["pybind-fp"] = self

    def add_opts(self, optparser):
        group = optparse.OptionGroup(optparser, "pybind-fp output specific options")
        group.add_option(
            "--pybind-components",
            dest="pybind_components",
            metavar="FILE",
            help="Components file (oper-components.txt) to fingerprint the components of",
        )
        group.add_option(
            "--pybind-unclaimed-out",
            dest="pybind_unclaimed_out",
            metavar="FILE",
            help="Also write the report of the state not claimed by any component to FILE",
        )
        optparser.add_option_group(group)

    def emit(self, ctx, modules, fd):
        if not ctx.opts.pybind_components:
            sys.stderr.write("FATAL: -f pybind-fp needs --pybind-components\n")
            sys.exit(1)
        comps = read_components(ctx.opts.pybind_components)

        # identity -> the identities based on it directly, over all the modules
        derived = {}
        for module in ctx.modules.values():
            for ident in module.search("identity"):
                for base in ident.search("base"):
                    base_ident = getattr(base, "i_identity", None)
                    if base_ident is not None:
                        derived.setdefault(id(base_ident), []).append(ident)
        for idents in derived.values():
            idents.sort(key=stmt_ref)

        targets_by_comp = {
            comp: [resolve_path(ctx, modules, path) for path in paths]
            for comp, paths in comps.items()
        }
        result = {
            comp: Hasher(derived).component(targets)
            for comp, targets in targets_by_comp.items()
        }
        fd.write(json.dumps({"components": result}, indent=1, sort_keys=True) + "\n")

        if ctx.opts.pybind_unclaimed_out:
            all_targets = {id(t) for targets in targets_by_comp.values() for t in targets}
            with open(ctx.opts.pybind_unclaimed_out, "w") as out:
                report_unclaimed(modules, all_targets, out)


class Hasher:
    def __init__(self, derived):
        self.derived = derived
        self.sha = hashlib.sha256()
        self.seen = set()

    def update(self, *fields):
        self.sha.update(("|".join(str(f) for f in fields) + "\n").encode())

    def component(self, targets):
        for target in targets:
            # The path down to the subtree: its nodes and their list keys
            chain = []
            node = target.parent
            while node is not None and node.keyword not in ("module", "submodule"):
                if node.keyword not in SKIPPED_PARENTS:
                    chain.append(node)
                node = node.parent
            for depth, ancestor in enumerate(reversed(chain)):
                self.update("A", depth, ancestor.keyword, ancestor.arg)
                for key in list_keys(ancestor):
                    key_stmt = next(
                        (c for c in getattr(ancestor, "i_children", []) if c.arg == key), None
                    )
                    if key_stmt is not None:
                        self.stmt(key_stmt, depth + 1)
            self.stmt(target, len(chain))
        return self.sha.hexdigest()

    def once(self, stmt):
        if id(stmt) in self.seen:
            self.update("SEEN", *stmt_ref(stmt))
            return False
        self.seen.add(id(stmt))
        return True

    def stmt(self, stmt, depth):
        self.update(depth, stmt.keyword, stmt.arg, getattr(stmt, "i_config", ""))
        if stmt.keyword == "type":
            self.type_refs(stmt, depth)
        leafref = getattr(stmt, "i_leafref_ptr", None)
        if leafref and leafref[0] is not None:
            target_type = leafref[0].search_one("type")
            self.update("LEAFREF", *stmt_ref(leafref[0]))
            if target_type is not None and self.once(target_type):
                self.stmt(target_type, depth + 1)
        for sub in stmt.substmts:
            if sub.keyword not in EXPANDED_KEYWORDS:
                self.stmt(sub, depth + 1)
        for child in getattr(stmt, "i_children", None) or []:
            self.stmt(child, depth + 1)

    def type_refs(self, type_stmt, depth):
        typedef = getattr(type_stmt, "i_typedef", None)
        if typedef is not None:
            self.update("TYPEDEF", *stmt_ref(typedef))
            if self.once(typedef):
                self.stmt(typedef, depth + 1)
        for base in type_stmt.search("base"):
            todo = [getattr(base, "i_identity", None)]
            while todo:
                ident = todo.pop(0)
                if ident is None:
                    continue
                self.update("IDENTITY", *stmt_ref(ident))
                if self.once(ident):
                    self.stmt(ident, depth + 1)
                    todo += self.derived.get(id(ident), [])
