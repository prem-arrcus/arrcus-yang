#!/usr/bin/env bash
# 
# Script to pull yang files from arrcus_sw repo
# Usage: ./pull.sh [branch=<aminor>] [target-dir=<branch>]
usage() {
    echo "./pull.sh [branch=<aminor>] [target-dir=<branch>] [repo=<git@github.com:Arrcus/arrcus_sw.git>]"
    echo
    echo "Example:"
    echo "  ./pull.sh aminor"
    echo
    exit 1
}
for arg in "$@"; do
    if [[ "$arg" =~ ^-.*$|.*\s-.*/$ ]]; then
        usage
    fi
done

set -euo pipefail
BRANCH="${1:-aminor}"
TARGET="${2:-$BRANCH}"
REPO="${3:-git@github.com:Arrcus/arrcus_sw.git}"

TOP_DIR="$(git rev-parse --show-toplevel)"
cd "$TOP_DIR"

INVOCATION_DIR="$(pwd -P)"
PREFIX=""
[ "$INVOCATION_DIR" == "$TOP_DIR" ] && PREFIX="" || PREFIX="${INVOCATION_DIR#${TOP_DIR}/}/"

# MODULE_NAME is the submodule name (--name, .git/modules dir, config key);
# TARGET_NAME is its path, which may carry the invocation-dir prefix.
if [[ -n "${2:-}" ]]; then
    # Explicit target dir: use as given (may be nested, e.g. confd/v8.2.3B),
    # module name is its leaf
    TARGET_NAME="${PREFIX}${TARGET}"
    MODULE_NAME="${TARGET##*/}"
else
    # Target derived from the branch name: flatten '/' so it is a single dir name
    TARGET_NAME="${PREFIX}${BRANCH//\//-}"
    MODULE_NAME="${BRANCH//\//-}"
fi

echo "BRANCH: $BRANCH, TARGET: $TARGET, REPO: $REPO"
echo "TARGET_NAME: $TARGET_NAME, MODULE_NAME: $MODULE_NAME, PREFIX: $PREFIX"
echo

echo "Shallow clone '$BRANCH' branch of $REPO"
if [ -d "${TARGET_NAME}" ]; then
    echo " -- Updating yang files"
    git -C "${TARGET_NAME}" pull --rebase
else
    echo " -- Pulling yang files"
    git clone --no-checkout --branch "${BRANCH}" --depth=1 --filter=blob:none --single-branch "${REPO}" "${TARGET_NAME}"

    grep -q '# Git submodules' .gitignore || echo -e "\n# Git submodules" >> $TOP_DIR/.gitignore
    printf '!%s\n' "${TARGET_NAME}" >> $TOP_DIR/.gitignore
fi
echo

if git config --get-all "submodule.${MODULE_NAME}.url" >/dev/null; then
    echo "Found submodule $TARGET_NAME"
else
    echo "Setting $TARGET_NAME as a git submodule"
    echo "git submodule add --name ${MODULE_NAME} ${REPO} ${TARGET_NAME}"
    git submodule add --name "${MODULE_NAME}" "${REPO}" "${TARGET_NAME}"
    git submodule absorbgitdirs -- "${TARGET_NAME}"
    echo
fi

echo "Setting sparse checkout to grab only yang files"
git -C "${TARGET_NAME}" config core.sparseCheckout true
echo '*.yang' >> .git/modules/${MODULE_NAME}/info/sparse-checkout
# The --no-checkout clone left an empty index; submodule update is a no-op
# when HEAD is already at the recorded sha, so check out explicitly.
git -C "${TARGET_NAME}" checkout -f "${BRANCH}"
echo

echo "Updating"
git submodule update --checkout "${TARGET_NAME}"
echo

echo "Done"
echo "$TARGET_NAME is sparse-checked-out with *.yang files from arrcus_sw repo (branch: $BRANCH)"
