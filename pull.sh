#!/usr/bin/env bash
# 
# Script to pull yang files from arrcus_sw repo
# Usage: ./pull.sh [branch=<aminor>] [target-dir=<branch>]
usage() {
    echo "./pull.sh [branch=<aminor>] [target-dir=<branch>]"
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

SW_REPO="git@github.com:Arrcus/arrcus_sw.git"
REPO_ROOT="$(git rev-parse --show-toplevel)"

git clone --no-checkout --branch "${BRANCH}" --depth=1 --filter=blob:none --single-branch "${SW_REPO}" "${TARGET}"

git submodule add "${SW_REPO}" "${TARGET}"
git submodule absorbgitdirs

git -C "${TARGET}" config core.sparseCheckout true
echo '*.yang' >> .git/modules/${TARGET}/info/sparse-checkout
git submodule update --force --checkout "${TARGET}"

echo "Done. $TARGET is sparse-checked-out with *.yang files from arrcus_sw repo (branch: $TARGET)"
