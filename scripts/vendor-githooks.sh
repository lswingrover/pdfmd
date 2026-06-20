#!/usr/bin/env bash
# vendor-githooks.sh — vendor the canonical git-hook dispatcher set from scotty
# (the PERSONAL-fleet source of truth) into THIS repo, then activate it. Run once per
# clone; re-run to update. Pin SCOTTY_GITHOOKS_REF to a tag/SHA for reproducibility.
#
# scotty mirrors laforge's framework (AG_DEV_POLICY §14.4) but is the source for
# PERSONAL repos, so the personal tree stays self-contained and doesn't depend on
# access to the private ambassador-group org. (laforge is the source for AG repos.)
# Personal-tree doctrine mirror: operating-principles.md § Branch-state discipline.
#
# Why vendor (not hand-copy): one source of truth in scotty/scripts/githooks/ — no
# drift across repos. Why this set: composable dispatchers (pre-commit / pre-push run
# every executable in their *.d/ dir), so a repo adds its own checks as a fragment
# without touching the universal base. Why git-native: the shared-checkout + main-guard
# fragments fire in Cowork AND Claude Code CLI, unlike the Bash-only PreToolUse hooks.
# Guard origin: lswingrover/obrien #39.
set -euo pipefail

SRC_REPO="${SCOTTY_REPO:-lswingrover/scotty}"
REF="${SCOTTY_GITHOOKS_REF:-main}"          # pin to a tag/SHA for reproducible vendoring
SUBPATH="scripts/githooks"
# Vendored alongside the hooks so the dispatcher base + universal fragments + the
# auto-push ("remote control") + the installer + the session helpers all travel
# together and the consuming repo is self-sufficient.
BASE_FILES="pre-commit pre-push post-commit CANONICAL.sha256"
BASE_FRAGS="pre-commit.d/20-shared-checkout pre-push.d/10-main-guard pre-commit.d/10-secret-scan"
HELPERS="scripts/install-git-hooks.sh scripts/session-worktree.sh scripts/new-session.sh scripts/vendor-githooks.sh"

command -v gh >/dev/null || { echo "vendor-githooks: gh CLI required" >&2; exit 1; }
ROOT=$(git rev-parse --show-toplevel) || { echo "vendor-githooks: not in a git repo" >&2; exit 1; }

fetch() {  # <repo-path> <dest-path> [chmod]
  mkdir -p "$(dirname "$2")"
  gh api "repos/$SRC_REPO/contents/$1?ref=$REF" --jq '.content' | base64 -d > "$2"
  [ "${3:-}" = "+x" ] && chmod +x "$2"
  echo "vendored: $1 -> ${2#"$ROOT"/}  ($SRC_REPO@$REF)"
}

for f in $BASE_FILES; do
  case $f in *.sha256) fetch "$SUBPATH/$f" "$ROOT/$SUBPATH/$f" ;; *) fetch "$SUBPATH/$f" "$ROOT/$SUBPATH/$f" +x ;; esac
done
for f in $BASE_FRAGS; do fetch "$SUBPATH/$f" "$ROOT/$SUBPATH/$f" +x; done
for f in $HELPERS;   do fetch "$f"          "$ROOT/$f"          +x; done

# Record provenance so drift from the source is detectable later.
gh api "repos/$SRC_REPO/commits/$REF" --jq '.sha' > "$ROOT/$SUBPATH/.githooks-ref"
echo "pinned scotty ref: $(cat "$ROOT/$SUBPATH/.githooks-ref")"

# Integrity: the vendored base must match the canonical checksums it shipped with.
( cd "$ROOT/$SUBPATH" && shasum -a 256 -c CANONICAL.sha256 ) \
  || { echo "vendor-githooks: vendored base failed CANONICAL.sha256 — aborting" >&2; exit 1; }

# Activate for this clone + every worktree (sets core.hooksPath; no .git/hooks copy).
bash "$ROOT/scripts/install-git-hooks.sh"
echo "done. commit the vendored scripts/githooks/ + scripts/ helpers so teammates inherit them."
