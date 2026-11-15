# Arrcus YANG Repository
This repository contains the YANG models published by Arrcus Inc.

## Fetching YANG files
The YANG files are fetched from the [arrcus_sw](https://github.com/Arrcus/arrcus_sw) repository
(or a fork of it) into a standalone, shallow, sparse-checkout clone, which has only the `*.yang`
files.

`pull.sh` clones a branch, or updates an existing clone to the branch's latest commit (or to a
specified commit). Before updating, it reverts `yang-changes.patch` (which the build applies), as
local changes would make the update fail.

```bash
./pull.sh [branch] [target-dir] [repo] [commit]
```

For example, `./pull.sh aminor` creates an `aminor/` directory with the `*.yang` files of the
`aminor` branch of `arrcus_sw`. The [confd](https://github.com/Arrcus/confd) YANG files are pulled
the same way:

```bash
./pull.sh v8.2.3B confd/v8.2.3B git@github.com:Arrcus/confd.git
```

## Building pyang bindings
`build_pyang_bindings.sh` generates Python bindings ([pyangbind](https://github.com/robshakir/pyangbind))
for the YANG files of a specified branch. It pulls the YANG files itself (via `pull.sh`) when
their clones don't exist, so there's no need to run `pull.sh` first. Existing clones are used as
they are.

```bash
./build_pyang_bindings.sh [branch] [target-dir] [repo] [confd-branch]
```

| Argument | Default | Description |
|---|---|---|
| `branch` | `aminor` | Branch of the `arrcus_sw` repo to take the YANG files from |
| `target-dir` | `<branch>` | Name of the output directory (any `/` is replaced by `-`) |
| `repo` | `git@github.com:Arrcus/arrcus_sw.git` | Repo to pull the YANG files from |
| `confd-branch` | `<branch>` | Branch of the [confd](https://github.com/Arrcus/confd) repo to take its YANG files from |

The `BINDINGS` environment variable picks the bindings to build (default: `full,config,oper`):

- `full`: `<build-dir>/bindings.py`, the bindings of all the YANG files
- `config`: `<build-dir>/config.py`, config-only bindings
- `oper`: `<build-dir>/oper/<component>.py`, one oper-state bindings file per component
  listed in `oper-components.txt`

The other environment variables:

| Variable | Default | Description |
|---|---|---|
| `JOBS` | `nproc`, at most 8 | How many pyang processes run in parallel |
| `INCREMENTAL` | `0` | `1`: rebuild only the bindings whose inputs changed since the build in `<build-dir>` (see [Incremental builds](PYANG_BINDINGS.md#incremental-builds)) |
| `SRC_DIR` | `<target-dir>` | Clone of the arrcus_sw YANG files |
| `CONFD_DIR` | `confd/<confd-branch>` | Clone of the confd YANG files |
| `BUILD_DIR` | `build/<target-dir>` | Where the bindings go |
| `LOG_DIR` | `logs/<target-dir>` | Where the logs go |

Along with the bindings, the build writes `<build-dir>/build-info.json` (the commits and
fingerprints it was built from, and what was rebuilt) and `<build-dir>/fingerprints.json`
(the fingerprint of each oper component).

`./build_pyang_bindings.sh fingerprint <args>` only prints the fingerprints of the build's inputs
(as JSON), and `./build_pyang_bindings.sh fingerprint-tools <args>` only `tools_fp`. The same
`yang_fp` and `tools_fp` give the same bindings.

For example, to build the config and oper bindings of the `aminor` branch:

```bash
BINDINGS=config,oper ./build_pyang_bindings.sh aminor
```

To build them from a branch of a fork of `arrcus_sw`, here `irfan/mcast-latest-v8.2.3B` of
`irfanm-arrcus/arrcus_sw`, with the confd YANG files of `v8.2.3B`. Passing `''` as the
target-dir keeps its default, so the bindings go to `build/irfan-mcast-latest-v8.2.3B/`:

```bash
BINDINGS=config,oper ./build_pyang_bindings.sh irfan/mcast-latest-v8.2.3B '' git@github.com:irfanm-arrcus/arrcus_sw.git v8.2.3B
```

See [PYANG_BINDINGS.md](PYANG_BINDINGS.md) for how and why the bindings are split.

## Contacts
prem@arrcus.com

