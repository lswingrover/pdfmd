#!/usr/bin/env bash
# new-session.sh <slug> — turnkey session isolation, descriptively named & matching.
#
# The operating model (AG_DEV_POLICY §14.4): 1 branch = 1 worktree = 1 session,
# with remote control. The <slug> is the ONE descriptive name shared by your
# session title, your branch, and your worktree — so the three always match and
# anyone can tell what each is at a glance. No random codenames.
#
# This one command:
#   - creates branch <slug> + matching worktree ../<repo>-wt-<slug> off origin/HEAD
#     (this repo's integration branch — dev in laforge, staging in enterprise-d, ...)
#   - copies .env essentials + links deps (immediately runnable)
#   - vendors (if needed) + activates the canonical git hooks: shared-checkout guard,
#     main-guard, secret-scan, and post-commit auto-push ("remote control")
#   - seeds origin/<slug> so the branch is under remote control from commit #1
#   - prints the cd
#
# Usage:  bash scripts/new-session.sh <kebab-slug>
#   e.g.  bash scripts/new-session.sh gmail-gcal-oauth
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel) || { echo "new-session: not in a git repo" >&2; exit 1; }

slug="${1:-}"
if ! printf '%s' "$slug" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
  cat >&2 <<'EOF'
usage: bash scripts/new-session.sh <kebab-slug>

  <kebab-slug> describes your task in lowercase-with-dashes. It becomes your
  session title, branch name, AND worktree name (so all three match). Examples:
    gmail-gcal-oauth    crelate-migration-people    schema-migrations-review
EOF
  exit 2
fi

# Zero-touch hooks. If this repo vendors the canonical set from a source (laforge for
# AG repos, scotty for personal) but hasn't yet (no integrity manifest present), bootstrap
# it; then activate (set core.hooksPath). Idempotent — a repo that already committed its
# vendored scripts/githooks/ just re-activates. Source repos (laforge/scotty) ship the
# manifest themselves, so they skip the vendor step and only activate.
if [ -f "$ROOT/scripts/vendor-githooks.sh" ] && [ ! -f "$ROOT/scripts/githooks/CANONICAL.sha256" ]; then
  bash "$ROOT/scripts/vendor-githooks.sh" >/dev/null 2>&1 || true
fi
bash "$ROOT/scripts/install-git-hooks.sh" >/dev/null 2>&1 || true

# Heavy lifting (worktree + env copy + deps) is session-worktree.sh's job.
# No --ref: session-worktree.sh defaults to origin/HEAD (this repo's integration
# branch — staging here, dev/main elsewhere), so this script is repo-agnostic.
out=$(bash "$ROOT/scripts/session-worktree.sh" "$slug" --link-deps)
dest=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE: //p' | tail -1)
if [ -z "$dest" ]; then
  printf '%s\n' "$out" >&2
  echo "new-session: could not determine the worktree path" >&2
  exit 1
fi

# Seed the remote branch now; the post-commit hook keeps it pushed thereafter.
git -C "$dest" push -u origin "$slug" >/dev/null 2>&1 || true

cat <<EOF

================================================================
✅ Session isolated — 1 branch = 1 worktree = 1 session, all named "$slug".
   branch  : $slug   (auto-pushes to origin/$slug on every commit)
   worktree: $dest
================================================================

👉 DO ALL YOUR WORK IN THE WORKTREE. Your next action:

   cd "$dest"

   Then set this session's title to "$slug" so title = branch = worktree.
   (The main checkout is the coordinator's — do not build/commit here.)
EOF
