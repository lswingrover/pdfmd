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
# Guard origin: obrien #39.
set -euo pipefail

# SELF-UPDATE SAFETY — must stay the first thing this script does.
#
# This script is in its own HELPERS list, so a re-vendor overwrites the file that is
# currently executing. Bash reads a script incrementally, BY BYTE OFFSET; it does not
# hold the whole text in memory. Replacing the file mid-run therefore makes the parser
# resume at the wrong place in the new text.
#
# Observed 2026-07-31, vendoring the discreet-denylist hook to the fleet: this file grew
# by three lines, bash resumed mid-token and died with
#     vendor-githooks.sh: line 44: syntax error near unexpected token `do'
# AFTER the fragment loop had already run from the OLD BASE_FRAGS. So the new hook was
# never fetched, seven "vendored:" lines had already printed, and it looked like it
# worked. Any future change to this file's LENGTH would do the same in every repo.
#
# Fix: re-exec from an immutable private copy, so the running text cannot change under
# us no matter what the fetch writes. $0 is used nowhere below (paths come from `git
# rev-parse --show-toplevel`), so running from a temp path is safe.
if [ -z "${VENDOR_GITHOOKS_SELF:-}" ]; then
  _self=$(mktemp -t vendor-githooks) || { echo "vendor-githooks: mktemp failed" >&2; exit 1; }
  cat "$0" > "$_self"
  export VENDOR_GITHOOKS_SELF="$_self"
  exec bash "$_self" "$@"
fi
trap 'rm -f "${VENDOR_GITHOOKS_SELF:-}"' EXIT

# Irreducible: a vendoring script must name the repo it vendors FROM, and this is
# already the config-sourced form ($SCOTTY_REPO wins). Override to re-point the
# fleet at a different source. dev-policy.md §8b exemption.
SRC_REPO="${SCOTTY_REPO:-lswingrover/scotty}"  # denylist:ignore — see comment above
REF="${SCOTTY_GITHOOKS_REF:-main}"          # pin to a tag/SHA for reproducible vendoring
SUBPATH="scripts/githooks"
# Vendored alongside the hooks so the dispatcher base + universal fragments + the
# auto-push ("remote control") + the installer + the session helpers all travel
# together and the consuming repo is self-sufficient.
BASE_FILES="pre-commit pre-push post-commit CANONICAL.sha256"
BASE_FRAGS="pre-commit.d/20-shared-checkout pre-push.d/10-main-guard pre-commit.d/10-secret-scan pre-commit.d/15-discreet-denylist"
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

# If the consuming repo gitignores *.d (a common Make/C/Swift convention), the dispatcher
# fragment dirs (pre-commit.d/, pre-push.d/) get silently dropped at `git add` time — the
# dispatchers would ship WITHOUT their guards (no main-guard / secret-scan / shared-checkout).
# Add a durable .gitignore exception so that can't happen. Idempotent.
for d in pre-commit.d pre-push.d; do
  if git -C "$ROOT" check-ignore "$SUBPATH/$d" >/dev/null 2>&1; then
    gi="$ROOT/.gitignore"
    grep -qxF "!$SUBPATH/$d/" "$gi" 2>/dev/null || \
      printf '\n# keep vendored git-hook fragment dirs despite a *.d ignore rule\n!%s/%s/\n' "$SUBPATH" "$d" >> "$gi"
    echo "vendor-githooks: added .gitignore exception for $SUBPATH/$d (was ignored by a *.d rule)"
  fi
done

# Record provenance so drift from the source is detectable later.
gh api "repos/$SRC_REPO/commits/$REF" --jq '.sha' > "$ROOT/$SUBPATH/.githooks-ref"
echo "pinned scotty ref: $(cat "$ROOT/$SUBPATH/.githooks-ref")"

# Integrity: the vendored base must match the canonical checksums it shipped with.
( cd "$ROOT/$SUBPATH" && shasum -a 256 -c CANONICAL.sha256 ) \
  || { echo "vendor-githooks: vendored base failed CANONICAL.sha256 — aborting" >&2; exit 1; }

# Activate for this clone + every worktree (sets core.hooksPath; no .git/hooks copy).
bash "$ROOT/scripts/install-git-hooks.sh"
echo "done. commit the vendored scripts/githooks/ + scripts/ helpers so teammates inherit them."
