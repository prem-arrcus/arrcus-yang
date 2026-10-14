#!/usr/bin/env bash

shopt -s extglob globstar
set -euo pipefail

#set -x

# Script to build py-yang bindings from tha yang files
# Usage: ./build_pyang_bindings.sh [branch=<aminor>]
usage() {
    echo "./build_pyang_bindings.sh [branch=<aminor>]"
    echo
    echo "Example:"
    echo "  ./build_pyang_bindings.sh aminor"
    echo
    exit 1
}
[[ "$@" =~ - ]] && usage

# Init vars
BRANCH="${1:-aminor}"
LOG_FILE=logs/build_pyang_bindings.log.txt

mkdir -p logs build

# Redirect stdout to logfile & stderr to both terminal & logfile
echo "Logs File: $LOG_FILE"
#exec > $LOG_FILE
#exec 2> >(tee --ignore-interrupts -a $LOG_FILE >&2)
exec > >(tee --ignore-interrupts -a $LOG_FILE >&2) 2>&1
echo

# Init functions
raw_hdr() {
  v="$@"
  echo "$v"
  printf -- "${DELIM:-=}%.0s" $(seq 1 ${#v})
  echo
}
hdr() { DELIM="="; raw_hdr "$@"; };
hdr2() { DELIM="-"; raw_hdr "|  --  $@"; };

die() {
  echo -e "$@" >&2
  exit 1
}

# Virtual Env
echo "Preparing virtual env"
VENV=".env"
if [ ! -d "$VENV" ]; then
    echo " -- Creating virtual env"
    uv venv $VENV || die "Creating python virtual venv ($VENV) failed"
    echo
else
    echo " -- Using existing virtual env"
fi
# Install needed python pkgs 
echo " -- Installing pyang module"
source ${VENV}/bin/activate || die "Activating python virtual venv ($VENV) failed"
uv pip install "git+ssh://git@github.com/prem-arrcus/pyang.git"
uv pip install "git+ssh://git@github.com/prem-arrcus/pyangbind.git"
echo 

# Find pyangbinf plugin path
PYBINDPLUGIN=$(python -c 'import pyangbind; import os; print ("{}/plugin".format(os.path.dirname(pyangbind.__file__)))')

# Pull needed yang files off specified branch from arrcus_sw repo
if [ ! -d "$BRANCH" ]; then
    echo "Pulling yang files"
    ./pull.sh $BRANCH || die "Pulling yang files from arrcus_sw repo (branch: $BRANCH) had failed"
    echo
fi

# Pull needed yang files off specified branch from confd repo
if [ ! -d "confd/$BRANCH" ]; then
    echo "Pulling confd"
    mkdir -p confd
    pushd confd
    ../pull.sh $BRANCH $BRANCH git@github.com:Arrcus/confd.git || die "Pulling yang files from confd repo (branch: $BRANCH) had failed"
    popd
    echo
fi

# Prepare
mkdir -p build/$BRANCH
pushd $BRANCH
CONFD=../confd/$BRANCH
echo "PYBINDPLUGIN: $PYBINDPLUGIN"
yang_modules=$(ls **/*.yang | grep -Ev "(deviations|annotations|ann).yang|^third_party" | cut -d' ' -f1 | xargs)
deviations="$(for f in **/*deviations.yang; do echo --deviation-module=$f; done | xargs)"
YANG_PATH="$(fd --type d --relative-path --regex '^(ui|snmp|cast)$' | tr '\n' :)$CONFD/src/confd/yang:$CONFD/src/confd/snmp/yang/:third_party/openconfig/models"

hdr "Building pyang bindings"
# Log all important vars
hdr2 "YANG Modules:"
echo "${yang_modules}" | tr ' ' '\n'
echo
hdr2 "Deviation files:"
echo "${deviations}" | tr ' ' '\n'
echo
hdr2 "YANG_PATH:"
echo "${YANG_PATH}" | tr ':' '\n'
echo
echo

# Build
echo "Building pyangbind bindings for all yang modules: " > /dev/stdout
echo -e "Invoking\n  -- pyang -Wnone --plugindir ${PYBINDPLUGIN} -f pybind --lax-quote-checks --ignore-error UNUSED_IMPORT ${deviations} --path=$YANG_PATH -o arcos/bindings.py ${yang_modules}"
#pyang -Wnone --plugindir ${PYBINDPLUGIN} -f pybind --lax-quote-checks --ignore-error UNUSED_IMPORT ${=deviations} --path=$YANG_PATH -o ../build/$BRANCH/bindings.py ${=yang_modules} || die "Building pyang bindings had failed"
pyang -Wnone --plugindir ${PYBINDPLUGIN} -f pybind --lax-quote-checks --ignore-error UNUSED_IMPORT --ignore-error XPATH_NODE_NOT_FOUND1 ${deviations} --path=$YANG_PATH -o ../build/$BRANCH/bindings.py ${yang_modules} || die "Building pyang bindings had failed"
popd
echo

# Final hacks
## TODO: Check if we really need this
sed -Ei 's/( YANGDynClass\([^"]*=str\()("\\[du])/\1r\2/' build/$BRANCH/bindings.py
sed -Ei 's/ ("""YANGDynClass\([^"]*=str\("\\[du])/ r\1/' build/$BRANCH/bindings.py


echo "Done"
echo "Bindings: build/$BRANCH/bindings.py"
