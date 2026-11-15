#!/usr/bin/env bash

shopt -s extglob globstar
set -euo pipefail

#set -x

# Script to build py-yang bindings from tha yang files
# Usage: ./build_pyang_bindings.sh [fingerprint] [branch=<aminor>] ...
usage() {
    echo "./build_pyang_bindings.sh [fingerprint] [branch=<aminor>] [target-dir=<branch>] [repo=<git@github.com:Arrcus/arrcus_sw.git>] [confd_branch=<branch>]"
    echo
    echo "  fingerprint                Only print the fingerprints of the inputs (JSON), don't build:"
    echo "                               yang_src_fp: the yang files (with yang-changes.patch applied)"
    echo "                               yang_fp:     yang_src_fp and oper-components.txt"
    echo "                               tools_fp:    the plugins, these scripts, BINDINGS and the"
    echo "                                            pyang/pyangbind versions"
    echo "                             The same yang_fp and tools_fp give the same bindings"
    echo "  fingerprint-tools          Only print tools_fp (JSON); needs no yang files"
    echo
    echo "Environment:"
    echo "  BINDINGS=full,config,oper  Bindings to build (default: all)"
    echo "                               full:   <build-dir>/bindings.py"
    echo "                               config: <build-dir>/config.py"
    echo "                               oper:   <build-dir>/oper/<component>.py, per oper-components.txt"
    echo "  JOBS=<n>                   Max pyang processes run in parallel (default: nproc, capped at 8)"
    echo "  INCREMENTAL=1              Rebuild only the bindings whose inputs changed since the build"
    echo "                             in <build-dir> (per <build-dir>/fingerprints.json). A full build,"
    echo "                             if that build's tools_fp differs"
    echo "  SRC_DIR=<dir>              Clone of the yang files (default: <target-dir>)"
    echo "  CONFD_DIR=<dir>            Clone of the confd yang files (default: confd/<confd_branch>)"
    echo "  BUILD_DIR=<dir>            Where the bindings go (default: build/<target-dir>)"
    echo "  LOG_DIR=<dir>              Where the logs go (default: logs/<target-dir>)"
    echo
    echo "The clones are pulled (by pull.sh), if they don't exist; existing ones are used as they are."
    echo
    echo "Example:"
    echo "  ./build_pyang_bindings.sh aminor"
    echo "  BINDINGS=config,oper ./build_pyang_bindings.sh aminor"
    echo "  BINDINGS=config,oper INCREMENTAL=1 ./build_pyang_bindings.sh aminor"
    echo
    exit 1
}
for arg in "$@"; do
    if [[ "$arg" =~ ^-h$|^--h.*$ ]]; then
        usage
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

MODE=build
if [[ "${1:-}" =~ ^fingerprint(-tools)?$ ]]; then
  MODE="$1"
  shift
fi

# Init vars
BRANCH="${1:-aminor}"
TARGET="${2:-$BRANCH}"
REPO="${3:-git@github.com:Arrcus/arrcus_sw.git}"
CONFD_BRANCH="${4:-$BRANCH}"
CONFD_REPO="git@github.com:Arrcus/confd.git"
PLUGIN_DIR="${SCRIPT_DIR}/plugins"
OPER_COMPONENTS="${SCRIPT_DIR}/oper-components.txt"
TARGET_NAME="${TARGET//\//-}"
BINDINGS="${BINDINGS:-full,config,oper}"
INCREMENTAL="${INCREMENTAL:-0}"
# Each pyang job holds the full parsed schema (~400MB), so don't scale with nproc blindly
JOBS="${JOBS:-$(( $(nproc) < 8 ? $(nproc) : 8 ))}"
# Absolute paths, as the build runs from within the clone
SRC_DIR="$(realpath -m "${SRC_DIR:-$TARGET_NAME}")"
CONFD_DIR="$(realpath -m "${CONFD_DIR:-confd/$CONFD_BRANCH}")"
BUILD_DIR="$(realpath -m "${BUILD_DIR:-build/$TARGET_NAME}")"
JOB_LOG_DIR="$(realpath -m "${LOG_DIR:-logs/$TARGET_NAME}")"
LOG_FILE="${JOB_LOG_DIR}/build_pyang_bindings.log"

# Init functions
raw_hdr() {
  v="$*"
  echo "$v"
  printf -- "${DELIM:-=}%.0s" $(seq 1 ${#v})
  echo
}
hdr() { DELIM="="; raw_hdr "$@"; };
hdr2() { DELIM="-"; raw_hdr "|  --  $*"; };

want() { [[ ",${BINDINGS}," == *",$1,"* ]]; }

apply_final_hacks() {
  ## TODO: Check if we really need this
  sed -Ei 's/( YANGDynClass\([^"]*=str\()("\\[du])/\1r\2/' "$1"
  sed -Ei 's/ ("""YANGDynClass\([^"]*=str\("\\[du])/ r\1/' "$1"
}

# sha256 of the stdin
sha() { sha256sum | cut -d' ' -f1; }

# sha256 of the *.yang files (paths and contents) under a dir, given a label for the dir
yang_files_sha() {
  local label="$1" dir="$2"
  shift 2
  (cd "$dir" && find "$@" -name .git -prune -o -type f -name '*.yang' -print0 2>/dev/null |
    LC_ALL=C sort -z | xargs -0 -r sha256sum) | sed "s|  |  ${label}/|"
}

# Sets YANG_SRC_FP, YANG_FP and TOOLS_FP (see usage). Call with the patch applied
compute_fingerprints() {
  YANG_SRC_FP="$({ yang_files_sha src "$SRC_DIR" .
                   yang_files_sha confd "$CONFD_DIR" src/confd/yang src/confd/snmp/yang; } | sha)"
  YANG_FP="$({ echo "$YANG_SRC_FP"; sha256sum < "$OPER_COMPONENTS"; } | sha)"
  compute_tools_fingerprint
}

compute_tools_fingerprint() {
  TOOLS_FP="$({ cd "$SCRIPT_DIR" && LC_ALL=C sha256sum plugins/*.py build_pyang_bindings.sh lib.sh
                echo "BINDINGS=$BINDINGS"
                pyang --version
                python3 -c 'import importlib.metadata as m; print("pyangbind", m.version("pyangbind"))'
              } | sha)"
}

# Run pyang with a plugin as a background job, at most JOBS at a time. Failures are recorded
# in FAILED_JOBS and checked after 'wait'
#   $1: job name, $2: output file, $3: output format, rest: extra pyang args
run_pyang() {
  local name="$1" out="$2" fmt="$3"
  shift 3
  local log="${JOB_LOG_DIR}/${name}.log"
  while (( $(jobs -rp | wc -l) >= JOBS )); do
    wait -n || true
  done
  echo " -- Started ${name}: ${out#"${BUILD_DIR}"/}"
  {
    if pyang -Wnone --plugindir "${PLUGIN_DIR}" -f "$fmt" --lax-quote-checks --ignore-error UNUSED_IMPORT --ignore-error XPATH_NODE_NOT_FOUND1 "${deviations[@]}" --path="$YANG_PATH" "$@" -o "$out" "${yang_modules[@]}" > "$log" 2>&1; then
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

wait_jobs() {
  # Wait for the pyang jobs only: a bare 'wait' also waits for the tee process
  # substitution logging stdout, which never exits while the script runs
  if (( ${#JOB_PIDS[@]} > 0 )); then
    wait "${JOB_PIDS[@]}" || true
  fi
  JOB_PIDS=()
  if [ -f "${FAILED_JOBS}" ]; then
    die "Building pyang bindings had failed for: $(xargs < "${FAILED_JOBS}")\nSee logs in ${JOB_LOG_DIR}"
  fi
}

# Validate options
for b in ${BINDINGS//,/ }; do
  [[ "$b" =~ ^(full|config|oper)$ ]] || die "Invalid BINDINGS entry '$b' (expected: full, config, oper)"
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "Invalid JOBS '$JOBS' (expected a positive number)"

mkdir -p "$JOB_LOG_DIR"
if [[ "$MODE" == build ]]; then
  mkdir -p "$BUILD_DIR"
  # Redirect stdout to logfile & stderr to both terminal & logfile
  echo "Logs File: $LOG_FILE"
  exec > >(tee --ignore-interrupts -a "$LOG_FILE" >&2) 2>&1
  echo
else
  # fingerprint*: keep stdout for the fingerprints only
  exec 3>&1 1>&2
fi

# Read the oper components: '<component> <schema-path>' per line
declare -A OPER_SUBTREES=()
OPER_COMPONENT_NAMES=()
if want oper; then
  [ -f "${OPER_COMPONENTS}" ] || die "${OPER_COMPONENTS} not found"
  while read -r comp path extra; do
    [[ -z "$comp" || "$comp" == \#* ]] && continue
    [[ -n "$path" && -z "$extra" ]] || die "${OPER_COMPONENTS##*/}: expected '<component> <schema-path>', got: $comp $path $extra"
    [[ "$comp" =~ ^[A-Za-z0-9_-]+$ ]] || die "${OPER_COMPONENTS##*/}: invalid component name '$comp'"
    [[ -n "${OPER_SUBTREES[$comp]+x}" ]] || OPER_COMPONENT_NAMES+=("$comp")
    # Space separated; paths can't contain whitespace, as the manifest is split on it
    OPER_SUBTREES[$comp]+=" --pybind-subtree=$path"
  done < "${OPER_COMPONENTS}"
  (( ${#OPER_COMPONENT_NAMES[@]} > 0 )) || die "No components found in ${OPER_COMPONENTS}"
fi

# Virtual Env
# Already in a venv (activated, or its python3 first in PATH): use it as is, as long as it
# has pyang and pyangbind. Otherwise, create (or reuse) .env here and install them into it.
in_venv() {
  [[ -n "${VIRTUAL_ENV:-}" ]] || python3 -c 'import sys; sys.exit(sys.prefix == sys.base_prefix)' 2>/dev/null
}
if in_venv; then
    echo "Using the current virtual env: ${VIRTUAL_ENV:-$(python3 -c 'import sys; print(sys.prefix)')}"
    command -v pyang >/dev/null || die "pyang isn't installed in the current virtual env. Install it with:\n  uv pip install git+ssh://git@github.com/prem-arrcus/pyang.git"
    python3 -c 'import pyangbind' 2>/dev/null || die "pyangbind isn't installed in the current virtual env. Install it with:\n  uv pip install git+ssh://git@github.com/prem-arrcus/pyangbind.git"
    echo " -- Found pyang ($(command -v pyang)) and pyangbind"
    echo
else
    echo "Preparing virtual env"
    VENV="${SCRIPT_DIR}/.env"
    if [ ! -d "$VENV" ]; then
        echo " -- Creating virtual env"
        uv venv "$VENV" || die "Creating python virtual venv ($VENV) failed"
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
fi

if [[ "$MODE" == fingerprint-tools ]]; then
  compute_tools_fingerprint
  printf '{"tools_fp": "%s"}\n' "$TOOLS_FP" >&3
  exit 0
fi

# Pull needed yang files off specified branch from arrcus_sw repo
# Check for a checkout, not just the dir: a submodule that isn't initialized (e.g. arrcus-yang
# checked out without --recursive) leaves behind an empty dir
if [ ! -e "$SRC_DIR/.git" ]; then
    echo "Pulling yang files"
    "${SCRIPT_DIR}/pull.sh" "$BRANCH" "$SRC_DIR" "$REPO" || die "Pulling yang files from $REPO (branch: $BRANCH) had failed"
    echo
fi

# Pull needed yang files off specified branch from confd repo
if [ ! -e "$CONFD_DIR/.git" ]; then
    echo "Pulling confd"
    "${SCRIPT_DIR}/pull.sh" "$CONFD_BRANCH" "$CONFD_DIR" "$CONFD_REPO" || die "Pulling yang files from $CONFD_REPO (branch: $CONFD_BRANCH) had failed"
    echo
fi

# Prepare
pushd "${SRC_DIR}" >/dev/null
apply_yang_patch
compute_fingerprints
if [[ "$MODE" == fingerprint ]]; then
  printf '{"yang_src_fp": "%s", "yang_fp": "%s", "tools_fp": "%s"}\n' "$YANG_SRC_FP" "$YANG_FP" "$TOOLS_FP" >&3
  exit 0
fi

echo "SRC_DIR: ${SRC_DIR}, BUILD_DIR: $BUILD_DIR, CONFD_DIR: $CONFD_DIR"
echo "PLUGIN_DIR: $PLUGIN_DIR, BINDINGS: $BINDINGS, JOBS: $JOBS, INCREMENTAL: $INCREMENTAL"
echo "YANG_FP: $YANG_FP, TOOLS_FP: $TOOLS_FP"
skip_modules_re='(deviations|annotations|ann).yang|^third_party'
yang_modules=()
for f in **/*.yang; do
  [ -e "$f" ] || continue
  [[ "$f" =~ $skip_modules_re ]] || yang_modules+=("$f")
done
(( ${#yang_modules[@]} > 0 )) || die "No yang files found in ${SRC_DIR}/; pulling them from $REPO (branch: $BRANCH) had probably failed"
deviations=()
for f in **/*deviations.yang; do
  [ -e "$f" ] || continue
  deviations+=("--deviation-module=$f")
done
YANG_PATH="$(fd --type d --relative-path --regex '^(ui|snmp|cast)$' | tr '\n' :)$CONFD_DIR/src/confd/yang:$CONFD_DIR/src/confd/snmp/yang/:third_party/openconfig/models"

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
echo -e "Invoking (per job)\n  -- pyang -Wnone --plugindir ${PLUGIN_DIR} -f <format> --lax-quote-checks --ignore-error UNUSED_IMPORT --ignore-error XPATH_NODE_NOT_FOUND1 ${deviations[*]} --path=$YANG_PATH <job-args> -o <output> ${yang_modules[*]}"
echo
FAILED_JOBS="${JOB_LOG_DIR}/failed-jobs.txt"
UNCLAIMED_REPORT="${JOB_LOG_DIR}/unclaimed-state.txt"
BUILD_INFO="${BUILD_DIR}/build-info.json"
FINGERPRINTS="${BUILD_DIR}/fingerprints.json"
NEW_FINGERPRINTS="${BUILD_DIR}/fingerprints.new.json"
rm -f "${FAILED_JOBS}" "${UNCLAIMED_REPORT}" "${NEW_FINGERPRINTS}"
JOB_PIDS=()

# Value of a key in a JSON file ('' if the file or the key doesn't exist)
json_get() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except (OSError, ValueError):
    print("")' "$1" "$2"
}

# Incremental build: only with fingerprints of an earlier build by the same tools
incremental=false
if [[ "$INCREMENTAL" == 1 ]]; then
  if [[ ! -f "$BUILD_INFO" || ! -f "$FINGERPRINTS" ]]; then
    echo "No earlier build in $BUILD_DIR to build incrementally from; building all"
  elif [[ "$(json_get "$BUILD_INFO" tools_fp)" != "$TOOLS_FP" ]]; then
    echo "The tools changed since the earlier build in $BUILD_DIR; building all"
  else
    incremental=true
  fi
fi

if want oper; then
  mkdir -p "${BUILD_DIR}/oper"
  # Each job gets its args in a separate var, as they are split on whitespace
  FP_ARGS=(--pybind-components="$OPER_COMPONENTS" --pybind-unclaimed-out="$UNCLAIMED_REPORT")
fi

REBUILT=()
if $incremental; then
  prev_yang_src_fp="$(json_get "$BUILD_INFO" yang_src_fp)"
  if want oper; then
    hdr2 "Fingerprinting the oper components"
    run_pyang fingerprints "$NEW_FINGERPRINTS" pybind-fp "${FP_ARGS[@]}"
    wait_jobs
  fi
  # Bindings to rebuild: config/full when any yang file changed (or missing), and the oper
  # components whose fingerprint changed (or missing). Removes the files of the components no
  # longer in oper-components.txt
  mapfile -t REBUILD < <(python3 - "$BUILD_DIR" "$FINGERPRINTS" "$NEW_FINGERPRINTS" \
      "$([[ "$prev_yang_src_fp" == "$YANG_SRC_FP" ]] && echo same || echo changed)" \
      "$BINDINGS" "${OPER_COMPONENT_NAMES[@]}" <<'EOF'
import json, sys
from pathlib import Path
build, old_fp, new_fp, yang, bindings, *comps = sys.argv[1:]
bindings = bindings.split(",")
build = Path(build)
for name, out in (("full", "bindings.py"), ("config", "config.py")):
    if name in bindings and (yang == "changed" or not (build / out).is_file()):
        print(name)
if "oper" in bindings:
    old = json.load(open(old_fp)).get("components", {})
    new = json.load(open(new_fp)).get("components", {})
    for comp in comps:
        out = build / "oper" / f"{comp.replace('-', '_')}.py"
        if old.get(comp) != new.get(comp) or not out.is_file():
            print(f"oper-{comp}")
    keep = {f"{comp.replace('-', '_')}.py" for comp in comps} | {"__init__.py"}
    for stale in (build / "oper").glob("*.py"):
        if stale.name not in keep:
            stale.unlink()
EOF
  )
  echo "To rebuild: ${REBUILD[*]:-nothing}"
  echo
else
  REBUILD=()
  want full && REBUILD+=(full)
  want config && REBUILD+=(config)
  if want oper; then
    # Remove stale outputs, e.g. of components no longer in the manifest
    rm -f "${BUILD_DIR}/oper/"*.py
    for comp in "${OPER_COMPONENT_NAMES[@]}"; do
      REBUILD+=("oper-${comp}")
    done
    run_pyang fingerprints "$NEW_FINGERPRINTS" pybind-fp "${FP_ARGS[@]}"
  fi
fi

for job in "${REBUILD[@]}"; do
  case "$job" in
    full)   run_pyang full "${BUILD_DIR}/bindings.py" pybind-split ;;
    config) run_pyang config "${BUILD_DIR}/config.py" pybind-split --pybind-filter=config ;;
    oper-*)
      comp="${job#oper-}"
      read -ra subtrees <<< "${OPER_SUBTREES[$comp]}"
      run_pyang "$job" "${BUILD_DIR}/oper/${comp//-/_}.py" pybind-split --pybind-filter=state "${subtrees[@]}"
      ;;
  esac
  REBUILT+=("$job")
done
wait_jobs
popd >/dev/null
echo

if [ -f "${UNCLAIMED_REPORT}" ] && grep -qv '^#' "${UNCLAIMED_REPORT}"; then
  hdr2 "WARNING: oper-state not covered by $(basename "${OPER_COMPONENTS}"):"
  cat "${UNCLAIMED_REPORT}"
  echo
fi

# Create __init__.py to make the creaed dirs as python modules
touch "${BUILD_DIR}/__init__.py"
want oper && touch "${BUILD_DIR}/oper/__init__.py"

# Record what the bindings were built from, for later incremental builds (and for DAF)
[ -f "$NEW_FINGERPRINTS" ] && mv "$NEW_FINGERPRINTS" "$FINGERPRINTS"
python3 - "$BUILD_INFO" <<EOF
import json, sys, time
json.dump({
    "branch": "$BRANCH",
    "repo": "$REPO",
    "commit": "$(git -C "$SRC_DIR" rev-parse HEAD)",
    "confd_branch": "$CONFD_BRANCH",
    "confd_commit": "$(git -C "$CONFD_DIR" rev-parse HEAD)",
    "bindings": "$BINDINGS",
    "yang_src_fp": "$YANG_SRC_FP",
    "yang_fp": "$YANG_FP",
    "tools_fp": "$TOOLS_FP",
    "mode": "$($incremental && echo incremental || echo full)",
    "rebuilt": "${REBUILT[*]}".split(),
    "built_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
}, open(sys.argv[1], "w"), indent=1)
EOF

echo "Done"
echo "Rebuilt: ${REBUILT[*]:-nothing}"
echo "Bindings:"
want full && ls -lh "${BUILD_DIR}/bindings.py"
want config && ls -lh "${BUILD_DIR}/config.py"
want oper && ls -lh "${BUILD_DIR}/oper/"*.py
exit 0
