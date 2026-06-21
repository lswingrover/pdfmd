#!/usr/bin/env bash
# Activate AG canonical git hooks for THIS clone (run once per clone; safe to re-run).
#
# Sets core.hooksPath to the repo's tracked hooks dir, so the hook SOURCE is versioned
# and travels with the repo: no copy step, edits take effect immediately, and it is
# worktree-correct (a relative core.hooksPath resolves per working tree, so every
# worktree of this clone gets the hooks automatically).
#
# Hooks are composable dispatchers: pre-push / pre-commit run every executable in their
# *.d/ dir, so a repo adds its own checks (plugin-staleness, skill validation, ...) as a
# fragment without touching the universal base. Canonical source:
# lswingrover/scotty scripts/githooks/. AG_DEV_POLICY §14.4.
#
#   bash scripts/install-git-hooks.sh            # activate (set core.hooksPath)
#   bash scripts/install-git-hooks.sh --verify   # check vendored base vs CANONICAL.sha256
set -eu
ROOT=$(git rev-parse --show-toplevel)

# Standardize on scripts/githooks; riker/ag-skills keep scripts/hooks (both supported).
HOOKS_REL=""
for REL in scripts/githooks scripts/hooks; do
  [ -d "$ROOT/$REL" ] && { HOOKS_REL="$REL"; break; }
done
[ -n "$HOOKS_REL" ] || { echo "no scripts/githooks or scripts/hooks dir in this repo" >&2; exit 1; }
DIR="$ROOT/$HOOKS_REL"

if [ "${1:-}" = "--verify" ]; then
  [ -f "$DIR/CANONICAL.sha256" ] || { echo "no $HOOKS_REL/CANONICAL.sha256 to verify against" >&2; exit 1; }
  ( cd "$DIR" && shasum -a 256 -c CANONICAL.sha256 )
  exit $?
fi

chmod +x "$DIR"/* 2>/dev/null || true
chmod +x "$DIR"/*.d/* 2>/dev/null || true
git config core.hooksPath "$HOOKS_REL"
echo "core.hooksPath = $HOOKS_REL  (AG canonical hooks active for this clone + its worktrees)"
echo "verify base integrity any time: bash scripts/install-git-hooks.sh --verify"
