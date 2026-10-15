#!/usr/bin/env bash

shopt -s extglob globstar
set -euo pipefail

#set -x

# Script to build py-yang bindings from tha yang files
# Usage: ./build_pyang_bindings.sh [branch=<aminor>]
usage() {
    echo "./build_pyang_bindings.sh [branch=<aminor>] [target-dir=<branch>] [repo=<git@github.com:Arrcus/arrcus_sw.git>] [confd_branch=<branch>"
    echo
    echo "Example:"
    echo "  ./build_pyang_bindings.sh aminor"
    echo
    exit 1
}
for arg in "$@"; do
    if [[ "$arg" =~ ^-h$|^--h.*$ ]]; then
        usage
    fi
done

# Init vars
BRANCH="${1:-aminor}"
TARGET="${2:-$BRANCH}"
REPO="${3:-git@github.com:Arrcus/arrcus_sw.git}"
PATCH_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/yang-changes.patch"
CONFD_BRANCH="${4:-$BRANCH}"
LOG_FILE=logs/build_pyang_bindings.log.txt
TARGET_NAME="${TARGET/\//-}"

mkdir -p logs build

# Redirect stdout to logfile & stderr to both terminal & logfile
echo "Logs File: $LOG_FILE"
#exec > $LOG_FILE
#exec 2> >(tee --ignore-interrupts -a $LOG_FILE >&2)
exec > >(tee --ignore-interrupts -a $LOG_FILE >&2) 2>&1
echo

# Init functions
apply_yang_patch() {
  if [[ ! -f "${PATCH_FILE}" ]]; then
    echo "No $(basename "${PATCH_FILE}") found; skipping patch"
    return 0
  fi
  if git apply --check --quiet "${PATCH_FILE}"; then
    echo "Applying $(basename "${PATCH_FILE}")"
    git apply --stat "${PATCH_FILE}" | tail -1
    git apply "${PATCH_FILE}" || die "Failed to apply ${PATCH_FILE}"
  elif git apply -R --check --quiet "${PATCH_FILE}"; then
    echo "$(basename "${PATCH_FILE}") is already applied; skipping"
  else
    # Not applicable: if every source file the patch expects is absent from
    # this branch (e.g. it targets a different repo layout), skip instead of failing
    local total=0 missing=0 f
    while IFS= read -r f; do
      [[ "$f" == "dev/null" ]] && continue
      total=$((total+1))
      [ -f "${f#a/}" ] || missing=$((missing+1))
    done < <(sed -n 's|^--- a/||p' "${PATCH_FILE}")
    if (( total > 0 && missing == total )); then
      echo "$(basename "${PATCH_FILE}") not applicable to this branch (source files absent); skipping"
      return 0
    fi
    die "Failed to apply ${PATCH_FILE}"
  fi
}

raw_hdr() {
  v="$@"
  echo "$v"
  printf -- "${DELIM:-=}%.0s" $(seq 1 ${#v})
  echo
}
hdr() { DELIM="="; raw_hdr "$@"; };
hdr2() { DELIM="-"; raw_hdr "|  --  $*"; };

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
if [ ! -d "$TARGET_NAME" ]; then
    echo "Pulling yang files"
    ./pull.sh $BRANCH $TARGET $REPO || die "Pulling yang files from arrcus_sw repo (branch: $BRANCH) had failed"
    echo
fi

# Pull needed yang files off specified branch from confd repo
if [ ! -d "confd/$CONFD_BRANCH" ]; then
    echo "Pulling confd"
    mkdir -p confd
    pushd confd >/dev/null
    ../pull.sh $CONFD_BRANCH '' git@github.com:Arrcus/confd.git || die "Pulling yang files from confd repo (branch: $BRANCH) had failed"
    popd >/dev/null
    echo
fi

# Prepare
BUILD_DIR="build/${TARGET_NAME}"
mkdir -p $BUILD_DIR
pushd ${TARGET_NAME} >/dev/null
apply_yang_patch
CONFD=../confd/$CONFD_BRANCH
echo "REPO: ${TARGET_NAME}, BUILD_DIR: $BUILD_DIR, Confd DIR: confd/$CONFD_BRANCH"
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
#pyang -Wnone --plugindir ${PYBINDPLUGIN} -f pybind --lax-quote-checks --ignore-error UNUSED_IMPORT ${=deviations} --path=$YANG_PATH -o ../${BUILD_DIR}/bindings.py ${=yang_modules} || die "Building pyang bindings had failed"
pyang -Wnone --plugindir ${PYBINDPLUGIN} -f pybind --lax-quote-checks --ignore-error UNUSED_IMPORT --ignore-error XPATH_NODE_NOT_FOUND1 ${deviations} --path=$YANG_PATH -o ../${BUILD_DIR}/bindings.py ${yang_modules} || die "Building pyang bindings had failed"
popd
echo

# Final hacks
## TODO: Check if we really need this
sed -Ei 's/( YANGDynClass\([^"]*=str\()("\\[du])/\1r\2/' ${BUILD_DIR}/bindings.py
sed -Ei 's/ ("""YANGDynClass\([^"]*=str\("\\[du])/ r\1/' ${BUILD_DIR}/bindings.py


echo "Done"
echo "Bindings: ${BUILD_DIR}/bindings.py"
