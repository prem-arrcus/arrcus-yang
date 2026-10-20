# Pyang Bindings
`build_pyang_bindings.sh` generates Python classes ([pyangbind](https://github.com/robshakir/pyangbind))
for the Arrcus YANG models. Besides the single all-in-one bindings file, it can split
the bindings into:

- **one config bindings file**, holding only `config true` nodes from every component
- **one oper-state bindings file per component** (bgp, ospf, rib, interfaces, ...),
  holding only the `config false` nodes for that component

## Building
```bash
./build_pyang_bindings.sh aminor
```

This produces:

| File                                    | Contents                                                       |
|-----------------------------------------|----------------------------------------------------------------|
| `build/<target>/bindings.py`            | Everything: config and state, all modules (same as before)     |
| `build/<target>/config_bindings.py`     | Config nodes only, all modules                                 |
| `build/<target>/oper/<comp>_bindings.py`| State nodes for one component, as listed in `oper-components.txt` |

A `-` in a component name becomes `_` in the file name (e.g. `sr-policy` → `oper/sr_policy_bindings.py`).

Two environment variables control the build:

| Variable   | Default             | Meaning                                                    |
|------------|---------------------|------------------------------------------------------------|
| `BINDINGS` | `full,config,oper`  | Which of the outputs above to build                        |
| `JOBS`     | `nproc`, at most 8  | How many pyang processes run in parallel                   |

```bash
# Skip the full bindings.py, build only config + oper files
BINDINGS=config,oper ./build_pyang_bindings.sh aminor
```

Each output is built by its own pyang process. Parsing and validating the whole
schema takes about 10s, so running these in parallel is cheap. A process holds
the full parsed schema in memory (~400MB), which is why `JOBS` is capped at 8.

Logs for each job go to `logs/<target>/<job>.log`. If any job fails, the build
fails and names the failed jobs.

## Why split the bindings?
The full `bindings.py` covers ~370 modules in one large file. Most users need only
part of it:

- tools that push configuration only need config nodes
- tools that read operational state usually care about one component at a time

Smaller files are faster to import and easier to read.

## Why components are defined by schema path
The obvious way to split would be by YANG module or by source directory. Neither
works for oper-state, because of how the Arrcus models are put together:

- Of the roughly 17k state leaves, about 14.4k sit under `/network-instances`.
  They are added there by augment modules, such as
  `arcos-openconfig-rib-bgp-augments` (7.1k leaves), `arcos-ospf` (1.8k) and
  `arcos-rib` (0.6k).
- Many of those modules live together in `mgmt/ui_common/ui`, whatever component
  they belong to.

So a module or directory does not map to a component. Instead, the manifest
`oper-components.txt` maps each component to one or more **schema subtree
paths**, and the oper file for that component contains the state found under
those paths.

(Figures are from the `irfan-mcast-latest-v8.2.3B` tree.)

## The manifest: `oper-components.txt`
Each line is `<component> <schema-path>`. Lines starting with `#` are comments.

```
bgp   /openconfig-network-instance:network-instances/network-instance/protocols/protocol/bgp
ospf  /openconfig-network-instance:network-instances/network-instance/protocols/protocol/arcos-ospf:ospfv2
ospf  /openconfig-network-instance:network-instances/network-instance/protocols/protocol/arcos-ospf:ospfv3
rib   /openconfig-network-instance:network-instances/network-instance/arcos-rib:rib
rib   /openconfig-network-instance:network-instances/network-instance/arcos-rib:rib-options
interfaces /openconfig-interfaces:interfaces
```

- **One file per component.** Repeat a component on several lines to give it
  several subtrees; they all go into the same file (`ospf` above gets both
  `ospfv2` and `ospfv3`).
- **Path syntax** is `/module:name/name/other-module:name/...`.
  - The prefix is the YANG **module name** (not the module's prefix).
  - The first segment always needs one. After that, a prefix is needed only where
    a node comes from a different module than its parent, e.g. an augment such as
    `arcos-ospf:ospfv2`.
  - `choice` and `case` nodes are not part of the path; they are looked through.
- **Paths must resolve.** A path that doesn't match a schema node, or that matches
  more than one node, fails the build with a message naming the bad segment. This
  catches YANG changes between branches.

### Adding a component
1. Find the top of the component's state in the schema tree, e.g. with
   `pyang -f tree`.
2. Add a `<component> <path>` line for each subtree.
3. Rebuild and check the coverage report (below).

### SNMP MIBs
All SNMP MIBs go into one file, `oper/snmp_mibs_bindings.py`, with one manifest
line per MIB top-level container:

```
snmp-mibs  /BGP4-MIB:BGP4-MIB
snmp-mibs  /IF-MIB:IF-MIB
...
```

Together they have about 2.1k state leaves. `SIMPLE-MIB` is left out: it has no
state and is only used in tests (`mgmt/confd_proxy/test`). MIBs that also have
config leaves (e.g. `RFC1213-MIB`, `BGP4-MIB`) show up in `config_bindings.py` too,
just as they do in `bindings.py`.

### IGMP
The `igmp` oper file is almost empty, and that is expected. In
`mgmt/ui_common/ui/arcos-igmp.yang` both `state` containers are empty because
their `uses` lines are commented out. The only state leaves are
`interface-ref/state/{interface,subinterface}`.

IGMP membership state is modelled under PIM instead (`arcos-pim-flock-oper`, and
the `igmp` flag in the `oil` list of `arcos-pim-oper`), so it ends up in the `pim`
oper file. This will change once the IGMP model gets real state.

## Coverage report
With `oper` enabled, the build also checks which state is not claimed by any
path in the manifest. It writes `logs/<target>/unclaimed-state.txt`, listing each
top-most unclaimed state subtree with its leaf count, and prints it as a warning
at the end of the build:

```
# <total> state leaves in <n> subtrees not claimed by any --pybind-subtree
<leaves>  <path>
...
```

This list should contain only intentional gaps, such as `arcos-debug` and
`*-clear` RPC-style trees. Anything else most likely needs a manifest entry.

## How the split works
The split is done by a small pyang plugin, `plugins/pybind_split.py`, which wraps
pyangbind's own `pybind` output format.

pyangbind has no option to filter by config/state or by subtree. However:

- by the time an output plugin runs, pyang has already set `i_config` on every
  schema node, so we know whether each node is config or state
- pyangbind simply emits one class per node in each module's `i_children`

So the plugin **prunes `i_children` in place**, then hands the modules to
pyangbind as usual. Whatever is left is what gets generated.

### Plugin options
The plugin registers a new output format, `-f pybind-split`. With no extra options
its output is the same as `-f pybind`, except for the submodule duplicates
described below. It adds:

| Option                         | Effect                                                             |
|--------------------------------|--------------------------------------------------------------------|
| `--pybind-filter=config`       | Keep only `config true` nodes                                      |
| `--pybind-filter=state`        | Keep only `config false` nodes                                     |
| `--pybind-subtree=<path>`      | Keep only nodes at or below `<path>`. Can be repeated              |
| `--pybind-report-unclaimed`    | Instead of bindings, write the coverage report for the given paths |

All of pyangbind's own options are still accepted.

### Pruning rules
- A **leaf** is kept if it is in scope (under one of the `--pybind-subtree` paths,
  or anywhere if none are given) and matches the filter.
- A **container or list** is kept if anything below it is kept. A presence
  container can also be kept on its own if it matches the filter.
- A kept **list always keeps its key leaves**, even config keys in a state file,
  because pyangbind's list classes refer to their keys by name.
- **Ancestors** of a subtree are kept only as the path down to it; their other
  children are dropped.
- `rpc`, `action` and `notification` nodes are always dropped.

Two things make this safe:

- **Every module stays in the module list**, even when its whole data tree is
  pruned away. pyangbind collects typedefs and identities from these modules. Some
  modules contain only types (e.g. `arcos-openconfig-bgp-types`) and supply derived
  identities that identityrefs rely on.
- **Leafrefs are generated as plain strings** (the build doesn't use
  `--use-xpathhelper`), so pruning away a leafref's target doesn't break anything.

### Submodule duplicates
pyangbind emits a module's whole data tree once for the module, and again for
every submodule the module includes. pyang has already merged the submodules'
nodes into the module, so these extra copies are identical trees under their own
top-level class (e.g. `openconfig_network_instance_l2`). Nothing in the module's
own tree refers to them. `openconfig-network-instance` includes
`openconfig-network-instance-l2`, so all of `/network-instances` was emitted twice,
which doubled the size of most oper files and added 8.5MB to the config file. The
plugin skips these copies.

## Why the bgp oper file is still large
Most of `oper/bgp_bindings.py` (~64MB of ~74MB) is `bgp/rib`. pyangbind generates a
separate class for every place a grouping is used. In
`arcos-openconfig-rib-bgp-augments.yang`, the `route-attr-set-top` grouping (the
"embedded path attributes" of a route, about 50 classes) is augmented into every
route list: loc-rib, adj-rib-in-pre, adj-rib-in-post and adj-rib-out of every
AFI-SAFI, 61 uses in all. That alone accounts for ~40MB. Each route also refers to
the same attributes in the shared `rib/attr-sets` through `attr-index`. Making
the file much smaller would mean changing the model, i.e. the API.

## Checking the output
Quick checks after a build:

- Every file parses and imports in the venv.
- `config_bindings.py` contains no state: `grep -c "is_config=False"` returns 0,
  `runtime-instances` is absent, and a BGP neighbor has `config` but no `state`.
- An oper file (e.g. `oper/bgp_bindings.py`) lets you create a network-instance,
  protocol and neighbor by key and set a `state` leaf, has no `config`
  containers, and loads a sample BGP oper JSON with `pybindJSON.loads`.
- The split files are each much smaller than `bindings.py`.
- Putting a bad path in the manifest makes the build fail with a clear message.
