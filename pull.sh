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

echo "Shallow clone '$BRANCH' branch of $REPO"
TARGET_NAME="${TARGET/\//-}"
if [ -d "${TARGET_NAME}" ]; then
    echo " -- Updating yang files"
    git -C "${TARGET_NAME}" pull --rebase
else
    echo " -- Pulling yang files"
    git clone --no-checkout --branch "${BRANCH}" --depth=1 --filter=blob:none --single-branch "${REPO}" "${TARGET_NAME}"

    grep -q '# Git submodules' .gitignore || echo -e "\n# Git submodules" >> .gitignore
    printf '!%s\n' "${TARGET_NAME}" >> .gitignore
fi
echo

if git config --get-all "submodule.${TARGET_NAME}.url" >/dev/null; then
    echo "Found submodule $TARGET_NAME"
else
    echo "Setting $TARGET_NAME as a git submodule"
    echo "git submodule add --name ${TARGET_NAME} ${REPO} ${TARGET_NAME}"
    git submodule add --name "${TARGET_NAME}" "${REPO}" "${TARGET_NAME}"
    git submodule absorbgitdirs -- "${TARGET_NAME}"
    echo
fi

echo "Setting sparse checkout to grab only yang files"
git -C "${TARGET_NAME}" config core.sparseCheckout true
echo '*.yang' >> .git/modules/${TARGET_NAME}/info/sparse-checkout
# The --no-checkout clone left an empty index; submodule update is a no-op
# when HEAD is already at the recorded sha, so check out explicitly.
git -C "${TARGET_NAME}" checkout -f "${BRANCH}"
echo

echo "Updating"
git submodule update --checkout "${TARGET_NAME}"
echo

echo "Done"
echo "$TARGET_NAME is sparse-checked-out with *.yang files from arrcus_sw repo (branch: $BRANCH)"
