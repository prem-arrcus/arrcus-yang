# shellcheck shell=bash
# Functions shared by pull.sh and build_pyang_bindings.sh. Source it; don't run it.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${PATCH_FILE:-${LIB_DIR}/yang-changes.patch}"

die() {
  echo -e "$@" >&2
  exit 1
}

# Apply yang-changes.patch to the clone in the current dir, unless it's applied already.
# Skipped, if none of the files the patch changes exist in the clone (e.g. confd)
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

# Undo yang-changes.patch in the clone in the current dir, if it's applied
revert_yang_patch() {
  [[ -f "${PATCH_FILE}" ]] || return 0
  if git apply -R --check --quiet "${PATCH_FILE}" 2>/dev/null; then
    echo "Reverting $(basename "${PATCH_FILE}")"
    git apply -R "${PATCH_FILE}" || die "Failed to revert ${PATCH_FILE}"
  fi
}
