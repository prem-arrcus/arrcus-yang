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
for the YANG files of a specified branch

```bash
./build_pyang_bindings.sh aminor
```

Besides the full `build/<target>/bindings.py`, this produces a config-only
`config_bindings.py` and one oper-state bindings file per component under `oper/`.
See [PYANG_BINDINGS.md](PYANG_BINDINGS.md) for how and why the bindings are split.

## Contacts
prem@arrcus.com

