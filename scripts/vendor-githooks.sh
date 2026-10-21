#!/usr/bin/env bash
# vendor-githooks.sh: vendor the git-hook dispatcher set (scripts/githooks/ plus the
# helper scripts named in HELPERS below) from its source repository into THIS repo,
# then activate it. Run once per clone; re-run to update. Pin GITHOOKS_SOURCE_REF to a
# tag/SHA for reproducibility.
#
# Why vendor (not hand-copy, not reference): one source of truth, byte-identical copies
# everywhere (CANONICAL.sha256 checks it), and each consuming repo stays self-contained:
# once vendored, installing its own guards needs no access to any other repository.
# Why this set: composable dispatchers (pre-commit / pre-push run every executable in
# their *.d/ dir), so a repo adds its own checks as a fragment without touching the
# universal base. Why git-native: the shared-checkout and main-guard fragments fire for
# every commit and push however git is invoked, unlike agent-side tool hooks, which only
# see commands run through the agent's own shell tool.
set -euo pipefail

# SELF-UPDATE SAFETY: must stay the first thing this script does.
#
# This script is in its own HELPERS list, so a re-vendor overwrites the file that is
# currently executing. Bash reads a script incrementally, BY BYTE OFFSET; it does not
# hold the whole text in memory. Replacing the file mid-run therefore makes the parser
# resume at the wrong place in the new text.
#
# If the new version differs in LENGTH, bash resumes mid-token and dies with a syntax
# error such as `syntax error near unexpected token `do'`, AFTER the fragment loop has
# already run from the OLD file lists. A newly added hook is then never fetched, several
# "vendored:" lines have already printed, and the run looks like it worked.
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

# WHERE THE HOOKS COME FROM: configured, never committed.
#
# This file is copied into every consuming repo and may be redistributed further, so a
# baked-in default would point a recipient's vendoring at somebody else's repository:
# they would either pull hooks from an account they have nothing to do with, or get a
# 404 with no way to interpret it. The script needs A source, not a particular one.
#
# Resolution order:
#   1. $GITHOOKS_SOURCE_REPO           explicit override, wins (legacy name: $SCOTTY_REPO)
#   2. ~/.config/githooks/source-repo  one line, "<owner>/<repo>"
#   3. hard error naming exactly what to set
#
# Deliberately NO default. A wrong default is worse than none here: it fails in the one
# direction nobody checks, successfully vendoring the wrong thing, quietly.
_cfg_home="${XDG_CONFIG_HOME:-$HOME/.config}"
SRC_REPO="${GITHOOKS_SOURCE_REPO:-${SCOTTY_REPO:-}}"
if [ -z "$SRC_REPO" ] && [ -r "$_cfg_home/githooks/source-repo" ]; then
  SRC_REPO=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$_cfg_home/githooks/source-repo" | grep -v '^$' | head -1)
fi
if [ -z "$SRC_REPO" ]; then
  cat >&2 <<ERR
vendor-githooks: no hook source repository configured.

  Set one of:
    export GITHOOKS_SOURCE_REPO="<owner>/<repo>"
  or write it once:
    mkdir -p "$_cfg_home/githooks"
    echo "<owner>/<repo>" > "$_cfg_home/githooks/source-repo"

  <owner>/<repo> is the GitHub repo holding the source scripts/githooks/ set.
  There is deliberately no default: vendoring from the wrong repo would succeed
  quietly, which is the one failure mode a guard-installer must not have.
ERR
  exit 1
fi
# Pin to a tag/SHA for reproducible vendoring (legacy name: SCOTTY_GITHOOKS_REF).
REF="${GITHOOKS_SOURCE_REF:-${SCOTTY_GITHOOKS_REF:-main}}"
SUBPATH="scripts/githooks"
# Vendored alongside the hooks so the dispatcher base + universal fragments + the
# post-commit backup ("remote control") + the installer + the session helpers all travel
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
# fragment dirs (pre-commit.d/, pre-push.d/) get silently dropped at `git add` time, and the
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
echo "pinned source ref: $(cat "$ROOT/$SUBPATH/.githooks-ref")"

# Integrity: the vendored base must match the canonical checksums it shipped with.
( cd "$ROOT/$SUBPATH" && shasum -a 256 -c CANONICAL.sha256 ) \
  || { echo "vendor-githooks: vendored base failed CANONICAL.sha256; aborting" >&2; exit 1; }

# Arm for this clone + every worktree (no .git/hooks copy). The installer keeps the
# current value, sets the relative one, or refuses when no value would arm every
# worktree. Its output is shown as-is. Exit 3 (no worktree is without hooks, but not all
# run the vendored set) is a warning; exit 1 (some worktree runs no hooks at all) fails
# this script, because "vendored" must never read as "running" when it is not.
hooks_rc=0
bash "$ROOT/scripts/install-git-hooks.sh" || hooks_rc=$?
case "$hooks_rc" in
  0) ;;
  3) echo "vendor-githooks: warning: vendored, but not every worktree runs the vendored set (see above)." >&2 ;;
  *) echo "vendor-githooks: files vendored and verified, but some worktree runs NO hooks at all (see above)." >&2
     exit 1 ;;
esac
echo "done. commit the vendored scripts/githooks/ + scripts/ helpers so teammates inherit them."
