"""
pyang plugin wrapping pyangbind's 'pybind' output format, so that bindings
can be generated for a subset of the schema tree.

  -f pybind-split                         same output as '-f pybind'
  --pybind-filter=config                  only config true nodes
  --pybind-filter=state                   only config false nodes
  --pybind-subtree=<path> (repeatable)    only nodes at/below these paths
  --pybind-report-unclaimed               list state subtrees not covered by
                                          any --pybind-subtree (no bindings)

Paths look like '/module:name/name/other-module:name/...'. The prefix is a
YANG module name, and is only needed where a segment is defined in a module
other than its parent's (e.g. an augment). choice/case nodes are not part of
the path.

Pruning happens in place on pyang's i_children before pyangbind runs. Every
module stays in the module list, since pyangbind gathers typedefs and
identities from them, even when their data tree is pruned away.
"""

import optparse
import sys

from pyang import plugin
from pyangbind.plugin import pybind

LEAF_KEYWORDS = ("leaf", "leaf-list", "anyxml", "anydata")
SKIP_KEYWORDS = ("rpc", "action", "notification", "input", "output")
TRANSPARENT_KEYWORDS = ("choice", "case")


def pyang_plugin_init():
    plugin.register_plugin(PybindSplit())


class PybindSplit(pybind.PyangBindClass):
    def add_output_format(self, fmts):
        self.multiple_modules = True
        fmts["pybind-split"] = self

    def add_opts(self, optparser):
        super().add_opts(optparser)
        option_group = optparse.OptionGroup(optparser, "pybind-split output specific options")
        option_group.add_option(
            "--pybind-filter",
            dest="pybind_filter",
            choices=["config", "state"],
            help="Only emit config true (config) or config false (state) nodes",
        )
        option_group.add_option(
            "--pybind-subtree",
            dest="pybind_subtrees",
            metavar="PATH",
            default=[],
            action="append",
            help="Only emit nodes at or below PATH. Can be given multiple times",
        )
        option_group.add_option(
            "--pybind-report-unclaimed",
            dest="pybind_report_unclaimed",
            action="store_true",
            help="Report state subtrees not covered by any --pybind-subtree, instead of emitting bindings",
        )
        optparser.add_option_group(option_group)

    def emit(self, ctx, modules, fd):
        opts = ctx.opts
        targets = {id(resolve_path(ctx, modules, p)) for p in opts.pybind_subtrees}

        if opts.pybind_report_unclaimed:
            report_unclaimed(modules, targets, fd)
            return

        if opts.pybind_filter or targets:
            if opts.pybind_filter == "config":
                keep = lambda s: getattr(s, "i_config", True) is not False
            elif opts.pybind_filter == "state":
                keep = lambda s: getattr(s, "i_config", True) is False
            else:
                keep = lambda s: True
            for module in modules:
                prune(module, keep, not targets, targets)

        pybind.build_pybind(ctx, modules, fd)


def die(msg):
    sys.stderr.write("FATAL: %s\n" % msg)
    sys.exit(1)


def defining_module(stmt):
    if hasattr(stmt, "main_module"):
        return stmt.main_module().arg
    return stmt.i_module.arg


def data_children(stmt):
    # Children as they appear in a data path, i.e. looking through choice/case
    for ch in getattr(stmt, "i_children", None) or []:
        if ch.keyword in SKIP_KEYWORDS:
            continue
        if ch.keyword in TRANSPARENT_KEYWORDS:
            yield from data_children(ch)
        else:
            yield ch


def resolve_path(ctx, modules, path):
    segments = [s for s in path.strip().split("/") if s]
    if not segments or ":" not in segments[0]:
        die("--pybind-subtree '%s': path must start with '/<module>:<name>'" % path)

    modname, name = segments[0].split(":", 1)
    module = next((m for m in modules if m.arg == modname), None)
    if module is None:
        die("--pybind-subtree '%s': module '%s' is not one of the modules being built" % (path, modname))

    node = module
    walked = ""
    for seg in segments:
        modname, name = seg.split(":", 1) if ":" in seg else (None, seg)
        matches = [
            ch for ch in data_children(node) if ch.arg == name and (modname is None or defining_module(ch) == modname)
        ]
        walked += "/" + seg
        if not matches:
            die("--pybind-subtree '%s': no schema node at '%s'" % (path, walked))
        if len(matches) > 1:
            die(
                "--pybind-subtree '%s': '%s' is ambiguous (defined in %s), add a module prefix"
                % (path, walked, ", ".join(sorted(defining_module(m) for m in matches)))
            )
        node = matches[0]
    return node


def list_keys(stmt):
    key = stmt.search_one("key") if stmt.keyword == "list" else None
    return key.arg.split() if key is not None else []


def prune(stmt, keep, in_scope, targets):
    """
    Filter stmt.i_children in place, recursively. A leaf survives if it is in
    scope and keep() accepts it; an interior node survives if anything below
    it does. Lists that survive always keep their key leaves. Returns whether
    anything other than list keys survived.
    """
    keys = list_keys(stmt)
    kept = []
    found = False
    for ch in getattr(stmt, "i_children", None) or []:
        if ch.keyword in SKIP_KEYWORDS:
            continue
        ch_in_scope = in_scope or id(ch) in targets
        if ch.keyword in LEAF_KEYWORDS or not hasattr(ch, "i_children"):
            if ch_in_scope and keep(ch):
                kept.append(ch)
                found = True
            elif ch.keyword == "leaf" and ch.arg in keys:
                kept.append(ch)
        elif prune(ch, keep, ch_in_scope, targets) or (
            ch.keyword == "container" and ch.search_one("presence") is not None and ch_in_scope and keep(ch)
        ):
            kept.append(ch)
            found = True
    stmt.i_children = kept
    return found


def count_state_leaves(stmt):
    n = 0
    for ch in data_children(stmt):
        if ch.keyword in LEAF_KEYWORDS or not hasattr(ch, "i_children"):
            n += getattr(ch, "i_config", True) is False
        else:
            n += count_state_leaves(ch)
    return n


def report_unclaimed(modules, targets, fd):
    # Ancestors of targets must be descended into; any other node is either
    # entirely unclaimed or entirely claimed. Ancestry is tracked while walking
    # the tree, since stmt.parent of an augmented node is the augment statement.
    target_ancestors = set()

    def mark(stmt, ancestors):
        for ch in data_children(stmt):
            if id(ch) in targets:
                target_ancestors.update(ancestors)
            else:
                mark(ch, ancestors + [id(ch)])

    for module in modules:
        mark(module, [])

    rows = []

    def walk(stmt, path, parent_mod):
        for ch in data_children(stmt):
            if id(ch) in targets:
                continue
            mod = defining_module(ch)
            ch_path = "%s/%s" % (path, ch.arg if mod == parent_mod else "%s:%s" % (mod, ch.arg))
            if id(ch) in target_ancestors:
                walk(ch, ch_path, mod)
            elif ch.keyword in LEAF_KEYWORDS or not hasattr(ch, "i_children"):
                if getattr(ch, "i_config", True) is False:
                    rows.append((ch_path, 1))
            else:
                n = count_state_leaves(ch)
                if n:
                    rows.append((ch_path, n))

    for module in modules:
        walk(module, "", None)

    total = sum(n for _, n in rows)
    fd.write("# %d state leaves in %d subtrees not claimed by any --pybind-subtree\n" % (total, len(rows)))
    for path, n in sorted(rows):
        fd.write("%6d  %s\n" % (n, path))
