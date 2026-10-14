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
[[ "$@" =~ - ]] && usage

set -euo pipefail
BRANCH="${1:-aminor}"
TARGET="${2:-$BRANCH}"

REPO="${3:-git@github.com:Arrcus/arrcus_sw.git}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "Shallow clone '$BRANCH' branch of $REPO"
if [ -d "${TARGET}" ]; then
    echo " -- Updating yang files"
    pushd "${TARGET}" >/dev/null
    git pull --rebase
    popd >/dev/null
else
    echo " -- Pulling yang files"
    git clone --no-checkout --branch "${BRANCH}" --depth=1 --filter=blob:none --single-branch "${REPO}" "${TARGET}"
fi
echo

git submodule 2>/dev/null | grep " ${TARGET} " && echo "Found submodule" || true
TARGET_NAME="${TARGET/\//-}"
if ! (git submodule 2>/dev/null | grep " ${TARGET} " 2>/dev/null); then
    echo "Setting it as git submodule"
    echo "git submodule add --name ${TARGET_NAME} ${REPO} ${TARGET}"
    git submodule add --name "${TARGET/\//-}" "${REPO}" "${TARGET}"
    git submodule absorbgitdirs -- "${TARGET}"
    echo
fi

echo "Setting sparse checkout to grab only yang files"
git -C "${TARGET}" config core.sparseCheckout true
echo '*.yang' >> .git/modules/${TARGET_NAME}/info/sparse-checkout
echo

echo "Updating"
git submodule update --force --checkout "${TARGET}"
echo

echo "Done"
echo "$TARGET is sparse-checked-out with *.yang files from arrcus_sw repo (branch: $TARGET)"
