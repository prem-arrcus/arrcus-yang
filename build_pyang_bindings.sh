#!/usr/bin/env bash

shopt -s extglob globstar
set -euo pipefail

#set -x

# Script to build py-yang bindings from tha yang files
# Usage: ./build_pyang_bindings.sh [branch=<aminor>]
usage() {
    echo "./build_pyang_bindings.sh [branch=<aminor>] [target-dir=<branch>] [repo=<git@github.com:Arrcus/arrcus_sw.git>] [confd_branch=<branch>"
    echo
    echo "Environment:"
    echo "  BINDINGS=full,config,oper  Bindings to build (default: all)"
    echo "                               full:   build/<target>/bindings.py"
    echo "                               config: build/<target>/config.py"
    echo "                               oper:   build/<target>/oper/<component>.py, per oper-components.txt"
    echo "  JOBS=<n>                   Max pyang processes run in parallel (default: nproc, capped at 8)"
    echo
    echo "Example:"
    echo "  ./build_pyang_bindings.sh aminor"
    echo "  BINDINGS=config,oper ./build_pyang_bindings.sh aminor"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/yang-changes.patch"
PLUGIN_DIR="${SCRIPT_DIR}/plugins"
OPER_COMPONENTS="${SCRIPT_DIR}/oper-components.txt"
CONFD_BRANCH="${4:-$BRANCH}"
LOG_FILE=logs/build_pyang_bindings.log.txt
TARGET_NAME="${TARGET//\//-}"
BINDINGS="${BINDINGS:-full,config,oper}"
# Each pyang job holds the full parsed schema (~400MB), so don't scale with nproc blindly
JOBS="${JOBS:-$(( $(nproc) < 8 ? $(nproc) : 8 ))}"
JOB_LOG_DIR="$(pwd)/logs/${TARGET_NAME}"

mkdir -p logs build "$JOB_LOG_DIR"

# Redirect stdout to logfile & stderr to both terminal & logfile
echo "Logs File: $LOG_FILE"
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
  v="$*"
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

want() { [[ ",${BINDINGS}," == *",$1,"* ]]; }

apply_final_hacks() {
  ## TODO: Check if we really need this
  sed -Ei 's/( YANGDynClass\([^"]*=str\()("\\[du])/\1r\2/' "$1"
  sed -Ei 's/ ("""YANGDynClass\([^"]*=str\("\\[du])/ r\1/' "$1"
}

# Run pyang with the pybind-split plugin as a background job, at most JOBS at
# a time. Failures are recorded in FAILED_JOBS and checked after 'wait'
#   $1: job name, $2: output file, rest: extra pyang args
run_pyang() {
  local name="$1" out="$2"
  shift 2
  local log="${JOB_LOG_DIR}/${name}.log"
  while (( $(jobs -rp | wc -l) >= JOBS )); do
    wait -n || true
  done
  echo " -- Started ${name}: ${out#../}"
  {
    if pyang -Wnone --plugindir "${PLUGIN_DIR}" -f pybind-split --lax-quote-checks --ignore-error UNUSED_IMPORT --ignore-error XPATH_NODE_NOT_FOUND1 "${deviations[@]}" --path="$YANG_PATH" "$@" -o "$out" "${yang_modules[@]}" > "$log" 2>&1; then
      if [[ "$out" == *.py ]]; then
        apply_final_hacks "$out"
      fi
      echo " -- Finished ${name}"
    else
      echo " -- FAILED ${name} (log: ${log})"
      echo "${name}" >> "${FAILED_JOBS}"
    fi
  } &
  JOB_PIDS+=($!)
}

# Validate options
for b in ${BINDINGS//,/ }; do
  [[ "$b" =~ ^(full|config|oper)$ ]] || die "Invalid BINDINGS entry '$b' (expected: full, config, oper)"
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "Invalid JOBS '$JOBS' (expected a positive number)"

# Read the oper components: '<component> <schema-path>' per line
declare -A OPER_SUBTREES=()
OPER_COMPONENT_NAMES=()
ALL_OPER_SUBTREES=()
if want oper; then
  [ -f "${OPER_COMPONENTS}" ] || die "${OPER_COMPONENTS} not found"
  while read -r comp path extra; do
    [[ -z "$comp" || "$comp" == \#* ]] && continue
    [[ -n "$path" && -z "$extra" ]] || die "${OPER_COMPONENTS##*/}: expected '<component> <schema-path>', got: $comp $path $extra"
    [[ "$comp" =~ ^[A-Za-z0-9_-]+$ ]] || die "${OPER_COMPONENTS##*/}: invalid component name '$comp'"
    [[ -n "${OPER_SUBTREES[$comp]+x}" ]] || OPER_COMPONENT_NAMES+=("$comp")
    # Space separated; paths can't contain whitespace, as the manifest is split on it
    OPER_SUBTREES[$comp]+=" --pybind-subtree=$path"
    ALL_OPER_SUBTREES+=("--pybind-subtree=$path")
  done < "${OPER_COMPONENTS}"
  (( ${#OPER_COMPONENT_NAMES[@]} > 0 )) || die "No components found in ${OPER_COMPONENTS}"
fi

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
# shellcheck source=/dev/null
source "${VENV}/bin/activate" || die "Activating python virtual venv ($VENV) failed"
uv pip install "git+ssh://git@github.com/prem-arrcus/pyang.git"
uv pip install "git+ssh://git@github.com/prem-arrcus/pyangbind.git"
echo

# Pull needed yang files off specified branch from arrcus_sw repo
if [ ! -d "$TARGET_NAME" ]; then
    echo "Pulling yang files"
    ./pull.sh "$BRANCH" "$TARGET_NAME" "$REPO" || die "Pulling yang files from arrcus_sw repo (branch: $BRANCH) had failed"
    echo
fi

# Pull needed yang files off specified branch from confd repo
if [ ! -d "confd/$CONFD_BRANCH" ]; then
    echo "Pulling confd"
    mkdir -p confd
    pushd confd >/dev/null
    ../pull.sh "$CONFD_BRANCH" '' git@github.com:Arrcus/confd.git || die "Pulling yang files from confd repo (branch: $BRANCH) had failed"
    popd >/dev/null
    echo
fi

# Prepare
BUILD_DIR="build/${TARGET_NAME}"
mkdir -p "$BUILD_DIR"
pushd "${TARGET_NAME}" >/dev/null
apply_yang_patch
CONFD=../confd/$CONFD_BRANCH
echo "REPO: ${TARGET_NAME}, BUILD_DIR: $BUILD_DIR, Confd DIR: confd/$CONFD_BRANCH"
echo "PLUGIN_DIR: $PLUGIN_DIR, BINDINGS: $BINDINGS, JOBS: $JOBS"
skip_modules_re='(deviations|annotations|ann).yang|^third_party'
yang_modules=()
for f in **/*.yang; do
  [[ "$f" =~ $skip_modules_re ]] || yang_modules+=("$f")
done
deviations=()
for f in **/*deviations.yang; do
  [ -e "$f" ] || continue
  deviations+=("--deviation-module=$f")
done
YANG_PATH="$(fd --type d --relative-path --regex '^(ui|snmp|cast)$' | tr '\n' :)$CONFD/src/confd/yang:$CONFD/src/confd/snmp/yang/:third_party/openconfig/models"

hdr "Building pyang bindings"
# Log all important vars
hdr2 "YANG Modules:"
printf '%s\n' "${yang_modules[@]}"
echo
hdr2 "Deviation files:"
printf '%s\n' "${deviations[@]}"
echo
hdr2 "YANG_PATH:"
echo "${YANG_PATH}" | tr ':' '\n'
echo
echo

# Build
echo "Building pyangbind bindings (per-job logs: ${JOB_LOG_DIR}/<job>.log)"
echo -e "Invoking (per job)\n  -- pyang -Wnone --plugindir ${PLUGIN_DIR} -f pybind-split --lax-quote-checks --ignore-error UNUSED_IMPORT --ignore-error XPATH_NODE_NOT_FOUND1 ${deviations[*]} --path=$YANG_PATH <job-args> -o <output> ${yang_modules[*]}"
echo
FAILED_JOBS="${JOB_LOG_DIR}/failed-jobs.txt"
UNCLAIMED_REPORT="${JOB_LOG_DIR}/unclaimed-state.txt"
rm -f "${FAILED_JOBS}" "${UNCLAIMED_REPORT}"
JOB_PIDS=()

if want full; then
  run_pyang full "../${BUILD_DIR}/bindings.py"
fi
if want config; then
  run_pyang config "../${BUILD_DIR}/config.py" --pybind-filter=config
fi
if want oper; then
  # Remove stale outputs, e.g. of components no longer in the manifest
  mkdir -p "../${BUILD_DIR}/oper"
  rm -f "../${BUILD_DIR}/oper/"*.py
  for comp in "${OPER_COMPONENT_NAMES[@]}"; do
    read -ra subtrees <<< "${OPER_SUBTREES[$comp]}"
    run_pyang "oper-${comp}" "../${BUILD_DIR}/oper/${comp//-/_}.py" --pybind-filter=state "${subtrees[@]}"
  done
  run_pyang unclaimed-state "${UNCLAIMED_REPORT}" --pybind-report-unclaimed "${ALL_OPER_SUBTREES[@]}"
fi
# Wait for the pyang jobs only: a bare 'wait' also waits for the tee process
# substitution logging stdout, which never exits while the script runs
wait "${JOB_PIDS[@]}" || true
popd >/dev/null
echo

if [ -f "${FAILED_JOBS}" ]; then
  die "Building pyang bindings had failed for: $(xargs < "${FAILED_JOBS}")\nSee logs in ${JOB_LOG_DIR}"
fi

if [ -f "${UNCLAIMED_REPORT}" ] && grep -qv '^#' "${UNCLAIMED_REPORT}"; then
  hdr2 "WARNING: oper-state not covered by $(basename "${OPER_COMPONENTS}"):"
  cat "${UNCLAIMED_REPORT}"
  echo
fi

# Create __init__.py to make the creaed dirs as python modules
touch "${BUILD_DIR}/__init__.py"
touch "${BUILD_DIR}/oper/__init__.py"

echo "Done"
echo "Bindings:"
want full && ls -lh "${BUILD_DIR}/bindings.py"
want config && ls -lh "${BUILD_DIR}/config.py"
want oper && ls -lh "${BUILD_DIR}/oper/"*.py
exit 0
