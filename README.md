# Arrcus YANG Repository
This repository contains the YANG models published by Arrcus Inc.

## Fetching YANG files
The YANG files are fetched from [arrcus_sw](https://github.com/Arrcus/arrcus_sw) repository,
exposed via a shallow sparse-checkout submodule

A helper utility `pull.sh` is provided to fetch the YANG files automatically for a 
specified branch.

For example, to pull the YANG files for `aminor` branch, you can invoke the `pull.sh` 
script pointing it to `aminor` branch

```bash
git clone git@github.com:Arrcus/arrcus-yang.git
cd arrcus-yang
./pull.sh aminor
```

This would result in a `aminor/` directory getting created, which would contain only
`*.yang` files from the `aminor` branch of `arrcus_sw` repo.

## Building pyang bindings
`build_pyang_bindings.sh` generates Python bindings ([pyangbind](https://github.com/robshakir/pyangbind))
for the YANG files of a specified branch. It pulls the YANG files itself (via `pull.sh`),
so there's no need to run `pull.sh` first.

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

- `full`: `build/<target>/bindings.py`, the bindings of all the YANG files
- `config`: `build/<target>/config.py`, config-only bindings
- `oper`: `build/<target>/oper/<component>.py`, one oper-state bindings file per component
  listed in `oper-components.txt`

`JOBS=<n>` sets how many pyang processes run in parallel (default: `nproc`, at most 8).

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

