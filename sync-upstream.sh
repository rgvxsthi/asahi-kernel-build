#!/bin/bash
# =============================================================================
# sync-upstream.sh
#
# Rebases the local patch branch on top of the latest upstream Asahi branch.
#
# Our branch layout:
#   upstream/fairydust   - AsahiLinux/linux fairydust (asahi-wip + DP alt mode)
#   rgvx/fairydust       - upstream/fairydust + our own commits on top
#
# Because our commits are always a linear series on top of upstream, syncing is
# just a rebase. Conflicts mean upstream touched the same code we patched, which
# usually means our patch was merged upstream and can be dropped.
#
# Usage:
#   ./sync-upstream.sh                 # rebase onto upstream/fairydust
#   BASE=asahi-wip ./sync-upstream.sh  # rebase onto a different upstream branch
# =============================================================================

set -euo pipefail

KDIR="${KDIR:-$HOME/Projects/Github/linux}"
BRANCH="${BRANCH:-rgvx/fairydust}"
BASE="${BASE:-fairydust}"
UPSTREAM_URL="https://github.com/AsahiLinux/linux.git"

cd "$KDIR"

if ! git remote get-url upstream >/dev/null 2>&1; then
    echo "[INFO] Adding upstream remote: $UPSTREAM_URL"
    git remote add upstream "$UPSTREAM_URL"
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "[ERROR] Working tree is dirty. Commit or stash first." >&2
    exit 1
fi

echo "[INFO] Fetching upstream/$BASE ..."
git fetch upstream "$BASE"

echo ""
echo "[INFO] Our commits on top of upstream/$BASE before rebase:"
git log --oneline "upstream/$BASE..$BRANCH" || true
echo ""

git checkout "$BRANCH"
git rebase "upstream/$BASE"

echo ""
echo "[OK] Rebased. Our commits are now:"
git log --oneline "upstream/$BASE..$BRANCH"
echo ""
echo "Kernel version: $(make kernelversion)"
echo ""
echo "Next: git push --force-with-lease origin $BRANCH"
echo "Then rebuild:  ./asahi-fairydust-build.sh"
