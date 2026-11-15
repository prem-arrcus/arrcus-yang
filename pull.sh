#!/usr/bin/env bash
#
# Clone (or update) the yang files of a branch of the arrcus_sw repo (or of another repo, e.g.
# confd) into a standalone, shallow, sparse (*.yang only) clone.
#
# An existing clone is updated to the branch's latest commit (or to the specified commit):
# yang-changes.patch is reverted first, as any other local change would make the update fail.
# The patch isn't applied again; build_pyang_bindings.sh does that.
usage() {
    echo "./pull.sh [branch=<aminor>] [target-dir=<branch, with '/' replaced by '-'>] [repo=<git@github.com:Arrcus/arrcus_sw.git>] [commit=<branch's latest>]"
    echo
    echo "Example:"
    echo "  ./pull.sh aminor"
    echo "  ./pull.sh v8.2.3B src/confd/v8.2.3B git@github.com:Arrcus/confd.git"
    echo
    exit 1
}
for arg in "$@"; do
    if [[ "$arg" =~ ^-h$|^--h.*$ ]]; then
        usage
    fi
done

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

BRANCH="${1:-aminor}"
TARGET="${2:-${BRANCH//\//-}}"
REPO="${3:-git@github.com:Arrcus/arrcus_sw.git}"
COMMIT="${4:-}"

echo "BRANCH: $BRANCH, TARGET: $TARGET, REPO: $REPO${COMMIT:+, COMMIT: $COMMIT}"

# Fetch the commit (or the branch's latest), as the only commit of the shallow clone's history.
# Prints the fetched commit
fetch() {
    local ref="${COMMIT:-refs/heads/${BRANCH}}"
    git -C "$TARGET" fetch --quiet --depth=1 --filter=blob:none origin "$ref" >&2 ||
        die "Fetching $ref of $REPO had failed"
    git -C "$TARGET" rev-parse FETCH_HEAD
}

# Check for a checkout, not just the dir: an uninitialized submodule leaves behind an empty dir,
# and 'git -C <empty dir>' would act on the repo containing it
if [ -e "${TARGET}/.git" ]; then
    url="$(git -C "$TARGET" remote get-url origin)"
    [[ "$url" == "$REPO" ]] || die "$TARGET is a clone of $url, not of $REPO"

    echo " -- Updating the yang files"
    (cd "$TARGET" && revert_yang_patch)
    if [[ -n "$(git -C "$TARGET" status --porcelain --untracked-files=no)" ]]; then
        die "$TARGET has local changes (other than $(basename "$PATCH_FILE")):\n$(git -C "$TARGET" status --short --untracked-files=no)"
    fi
    old="$(git -C "$TARGET" rev-parse HEAD)"
    new="$(fetch)"
    if [[ "$old" == "$new" ]]; then
        echo " -- Already at ${new}"
    else
        git -C "$TARGET" checkout --quiet -f -B "$BRANCH" "$new"
        echo " -- Updated ${old} -> ${new}"
    fi
else
    echo " -- Cloning the yang files"
    # 'git clone' accepts an existing empty dir
    git clone --quiet --no-checkout --branch "$BRANCH" --depth=1 --filter=blob:none --single-branch "$REPO" "$TARGET"
    new="$(git -C "$TARGET" rev-parse HEAD)"
    if [[ -n "$COMMIT" && "$COMMIT" != "$new" ]]; then
        new="$(fetch)"
    fi

    echo " -- Setting sparse checkout, to grab only the yang files"
    git -C "$TARGET" config core.sparseCheckout true
    # Ask git for the path: the git dir isn't always <target>/.git
    SPARSE_FILE="$(git -C "$TARGET" rev-parse --path-format=absolute --git-path info/sparse-checkout)"
    mkdir -p "$(dirname "$SPARSE_FILE")"
    echo '*.yang' > "$SPARSE_FILE"
    # The --no-checkout clone left an empty index, so check out explicitly
    git -C "$TARGET" checkout --quiet -f -B "$BRANCH" "$new"
    echo " -- Cloned ${new}"
fi

echo "Done"
echo "$TARGET has the *.yang files of $REPO (branch: $BRANCH, commit: $(git -C "$TARGET" rev-parse HEAD))"
