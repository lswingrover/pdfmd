#!/usr/bin/env bash
# new-session.sh <slug> — turnkey session isolation, descriptively named & matching.
#
# The operating model (dev-policy.md §2): 1 branch = 1 worktree = 1 session,
# with remote control. The <slug> is the ONE descriptive name shared by your
# session title, your branch, and your worktree — so the three always match and
# anyone can tell what each is at a glance. No random codenames.
#
# This one command:
#   - creates branch <slug> + matching worktree ../<repo>-wt-<slug> off this repo's
#     integration branch (dev in some repos, staging in others, else the
#     remote default) — resolved by resolve_base_ref(), NOT origin/HEAD, which mirrors the
#     remote default (main) and is wrong for the dev-first repos.
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

# --- Resolve this repo's integration branch as a remote-tracking ref (origin/<branch>) ---
# origin/HEAD is the WRONG signal on this fleet: it mirrors the remote's DEFAULT branch
# (main), but the dev-first repos integrate on 'dev' while origin/HEAD
# still points at main — so basing a worktree on origin/HEAD strands it on main in exactly
# the repos that ship dev-first. Resolve, in order: (1) explicit override git config
# session.integrationBranch; (2) convention — first EXISTING of origin/dev, origin/staging
# (exact refs; no fleet repo has both, so a dev-first repo resolves to dev and a
# staging-first repo to staging); (3) origin/HEAD.
resolve_base_ref() {
  local d="${1:-.}" cfg cand def
  cfg=$(git -C "$d" config --get session.integrationBranch 2>/dev/null || true)
  # Legacy key, read-only fallback. Renamed 2026-08-02 to drop an org prefix from a
  # generic setting; no repo on this fleet sets either, but a clone elsewhere might, and
  # silently ignoring a config someone set is worse than carrying two lines.
  [ -z "${cfg:-}" ] && cfg=$(git -C "$d" config --get ag.integrationBranch 2>/dev/null || true)
  if [ -n "$cfg" ] && git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$cfg"; then
    printf 'origin/%s\n' "$cfg"; return 0
  fi
  for cand in dev staging; do
    if git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$cand"; then
      printf 'origin/%s\n' "$cand"; return 0
    fi
  done
  def=$(git -C "$d" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/##') || def=""
  [ -n "$def" ] && { printf '%s\n' "$def"; return 0; }
  return 1
}

slug="${1:-}"
if ! printf '%s' "$slug" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
  cat >&2 <<'EOF'
usage: bash scripts/new-session.sh <kebab-slug>

  <kebab-slug> describes your task in lowercase-with-dashes. It becomes your
  session title, branch name, AND worktree name (so all three match). Examples:
    add-oauth-refresh   migrate-people-records      schema-migrations-review
EOF
  exit 2
fi

# --- Atomic slug claim (#432): the remote branch IS the lock ---
# Two sessions (any machine) racing the same slug: the first to create
# refs/heads/<slug> on origin wins; the second fails HERE, loudly, before any
# local side effects. Two steps because git makes the obvious one-step claim
# unsound: pushing a sha the remote ref already has is a silent no-op (exit 0)
# even under --force-with-lease — and racing sessions cut from the same
# integration tip push the SAME sha. So: (1) create-only push of a sha UNIQUE
# to this claimant (a throwaway commit-tree child of base; lease "<ref>:" =
# "must not exist"), then (2) lease-swap the ref back to base, leaving the
# branch seeded exactly as the old seed-push did. The claim commit becomes
# unreachable and is GC'd. Empirically verified 2026-07-09 (same-sha no-op,
# unique-sha rejection, swap-to-base).
#
# Both claim pushes run with SKIP_PREPUSH_CHECKS=1 (#864). The claim push carries
# ONLY the base tree — it introduces no content and cannot make the shared base
# red — so gating it on the pre-push quality job (prettier/lint/typecheck) is a
# category error: it runs against THIS checkout's dirty working tree (coordinator
# WIP, untracked drafts) and failed session creation for problems the pushing
# session did not create and cannot fix. SKIP_PREPUSH_CHECKS gates only
# pre-push.d/20-fast-checks; main-guard and author-guard still run, and the
# session's OWN branch push later faces the full unchanged gate.
git fetch origin --quiet
base_ref=$(resolve_base_ref "$ROOT") || base_ref=""
if [ -z "$base_ref" ]; then
  echo "new-session: cannot resolve an integration branch (no origin/dev, origin/staging, or origin/HEAD)." >&2
  echo "  set one explicitly:  git config session.integrationBranch <branch>   (or: git remote set-head origin -a)" >&2
  exit 1
fi
base_sha=$(git rev-parse "$base_ref")

# --- Tooling-drift gate (#1024, field note 80): never build a session with STALE tooling ---
# This script and session-worktree.sh execute from THIS checkout's working tree, but the
# worktree they create is cut from the integration branch (resolved above) — so a checkout
# that lags it runs tooling the fleet has since replaced, with the fix sitting merged upstream.
# Lived twice: a detached primary 148 behind ran the pre-#867 script and failed with a
# misleading "(network/auth?)" (#1026); stale primaries kept running the pre-pnpm
# --link-deps script after #1298 and reproduced the #1275 TS2307 block. The fetch above
# makes the comparison free; fail HERE, before the claim push, so there are no side
# effects to unwind. Intentionally iterating on locally-edited tooling is the one
# legitimate drift: SESSION_TOOLING_DRIFT_OK=1 bypasses.
TOOLING="scripts/new-session.sh scripts/session-worktree.sh"
if [ "${SESSION_TOOLING_DRIFT_OK:-0}" != 1 ] \
   && ! git -C "$ROOT" diff --quiet "$base_sha" -- $TOOLING; then
  drifted=$(git -C "$ROOT" diff --name-only "$base_sha" -- $TOOLING | tr '\n' ' ')
  cat >&2 <<EOF
new-session: session tooling in this checkout differs from $base_ref — refusing to
  build a session with stale tooling: $drifted
  Freshen the whole checkout (preferred):  git -C "$ROOT" pull --ff-only
  Or just the tooling files:               git -C "$ROOT" checkout $base_ref -- $TOOLING
  Intentionally testing edited tooling:    SESSION_TOOLING_DRIFT_OK=1 bash scripts/new-session.sh $slug
EOF
  exit 4
fi
claim_sha=$(git commit-tree "$base_sha^{tree}" -p "$base_sha" \
  -m "session claim: $slug ($(hostname -s 2>/dev/null || hostname) pid $$ $(date -u +%Y-%m-%dT%H:%M:%SZ))")
claim_err=$(SKIP_PREPUSH_CHECKS=1 git push --force-with-lease="refs/heads/$slug:" origin "$claim_sha:refs/heads/$slug" 2>&1) || claim_rc=$?
if [ "${claim_rc:-0}" -ne 0 ]; then
  if git ls-remote --exit-code --heads origin "$slug" >/dev/null 2>&1; then
    repo_base=$(basename "$ROOT")
    cat >&2 <<EOF
new-session: slug '$slug' is already claimed — origin/$slug exists.
  Another session (possibly on another machine) owns this slug.
  - Working on something else?  Pick a different slug.
  - Resuming THAT session?      cd into its existing worktree (../${repo_base}-wt-$slug),
                                or recreate it: git worktree add "../${repo_base}-wt-$slug" "$slug"
EOF
    exit 3
  fi
  # Not a collision (origin/$slug does not exist) — so a genuine push failure.
  # Surface the actual git output instead of guessing "network/auth?" (#864).
  echo "new-session: could not seed origin/$slug — refusing to proceed unclaimed." >&2
  echo "  git push failed with:" >&2
  printf '%s\n' "$claim_err" | sed 's/^/    /' >&2
  exit 1
fi
if ! SKIP_PREPUSH_CHECKS=1 git push --force-with-lease="refs/heads/$slug:$claim_sha" origin "+$base_sha:refs/heads/$slug" >/dev/null 2>&1; then
  echo "new-session: claim reset failed — origin/$slug changed under us; investigate: git ls-remote origin $slug" >&2
  exit 1
fi

# Zero-touch hooks. If this repo vendors the canonical set from its source repo but
# hasn't yet (no integrity manifest present), bootstrap
# it; then activate (set core.hooksPath). Idempotent — a repo that already committed its
# vendored scripts/githooks/ just re-activates. The source repo ships the
# manifest themselves, so they skip the vendor step and only activate.
if [ -f "$ROOT/scripts/vendor-githooks.sh" ] && [ ! -f "$ROOT/scripts/githooks/CANONICAL.sha256" ]; then
  bash "$ROOT/scripts/vendor-githooks.sh" >/dev/null 2>&1 || true
fi
bash "$ROOT/scripts/install-git-hooks.sh" >/dev/null 2>&1 || true

# --- Drop the worktree-bypass guard into THIS (primary) checkout's pre-commit.d ---
# Distribution "rides the worktree tooling": the 30-worktree-bypass guard is NOT in the
# vendored canonical base — it appears in a repo exactly because/when you ran this to
# isolate a session there, and is absent for anyone who never does. It fires ONLY in the
# primary checkout (flags committing on an integration branch here while a live session
# worktree exists — the "I have a worktree but committed in the shared checkout anyway"
# bypass). Written untracked + added to .git/info/exclude (local only — never committed or
# shared); the dispatcher runs it from the filesystem regardless of git status. Idempotent
# (only writes if absent). Warn-by-default; WORKTREE_BYPASS_ENFORCE=1 blocks, WORKTREE_BYPASS_OK=1 silences.
PCD="$ROOT/scripts/githooks/pre-commit.d"
FRAG="$PCD/30-worktree-bypass"
if [ -d "$PCD" ] && [ ! -e "$FRAG" ]; then
  cat > "$FRAG" <<'WTBYPASS'
#!/usr/bin/env bash
# 30-worktree-bypass — flag committing into the PRIMARY checkout on an integration
# branch while a LIVE session-convention worktree exists (the "I was handed a worktree
# but committed to dev in the shared checkout anyway" bypass).
#
# Distribution rides the worktree tooling: new-session.sh / session-worktree.sh drop this
# into the primary checkout's pre-commit.d/ when they create a worktree (local, untracked,
# .git/info/exclude'd) — present exactly where/when you isolate, absent otherwise. NOT part
# of the vendored canonical base. Source of record: scotty
# new-session.sh. Companion to hooks/sessionstart-worktree-reaper.py (clears the DEAD ones).
#
# WHY THIS EXISTS ALONGSIDE 20-shared-checkout:
# 20-shared-checkout deliberately EXEMPTS integration branches (main/dev/staging) — those
# are where multiple sessions are expected to land work. So it does NOT catch the distinct
# failure where a session that was given its OWN isolated worktree nonetheless commits
# directly into the shared primary checkout on dev/main, skipping the worktree -> PR -> merge
# flow. That bypass strands the worktree and reintroduces the shared-checkout race.
#
# BEHAVIOR (default WARN, never blocks the dev-first ship pipeline, which legitimately
# commits to dev in the primary checkout):
#   - default                       -> print a loud warning to stderr, exit 0 (allow).
#   - WORKTREE_BYPASS_ENFORCE=1      -> hard block (exit 1). Opt-in strict mode.
#   - WORKTREE_BYPASS_OK=1           -> silently allow (the ship/coordinator escape hatch).
set -eu

[ "${WORKTREE_BYPASS_OK:-0}" = 1 ] && exit 0

# 1. PRIMARY checkout only. In a linked worktree, --git-dir != --git-common-dir.
GD=$(git rev-parse --git-dir 2>/dev/null) || exit 0
CD=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GD" != "$CD" ] && exit 0   # linked worktree — committing here is correct, allow

# 2. Integration branch only.
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)
INT="${INTEGRATION_BRANCHES:-main master dev develop staging}"
on_int=0; for b in $INT; do [ "$BRANCH" = "$b" ] && on_int=1; done
[ "$on_int" = 1 ] || exit 0

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
REPO=$(basename "$TOP")

# 3. Any LIVE session-convention worktree? Let python filter the worktree list by
#    convention + liveness (the registry read mirrors 20-shared-checkout exactly).
#    NB: pass the worktree list via env, NOT a pipe — `cmd | python3 - <<'PY'` makes the
#    heredoc win stdin, so a piped list is silently dropped.
LIVE_WT=$(REPO="$REPO" WTLIST="$(git worktree list --porcelain 2>/dev/null)" python3 - <<'PY' 2>/dev/null || true
import hashlib, json, os, time, glob
repo = os.environ.get("REPO", "")
wtlist = os.environ.get("WTLIST", "")
LIVE = 30 * 60
reg = os.path.join(os.path.expanduser("~"), ".claude", "checkout-locks")
tmp = os.environ.get("TMPDIR", "/tmp").rstrip("/")

def is_conv(path):
    base = os.path.basename(path)
    if "/.claude/worktrees/" in path:
        return True
    if f"{repo}-wt-" in base:
        return True
    for root in (tmp, "/tmp", "/private/tmp"):
        if path.startswith(root + "/") and base.startswith(f"{repo}-"):
            return True
    return False

def live_owner(path):
    key = hashlib.sha1(path.encode()).hexdigest()[:16]
    d = os.path.join(reg, key)
    if not os.path.isdir(d):
        return False
    for f in glob.glob(os.path.join(d, "*.json")):
        try:
            e = json.load(open(f)); tp = e.get("transcript_path")
            if tp and os.path.exists(tp):
                if (time.time() - os.path.getmtime(tp)) < LIVE: return True
            elif (time.time() - os.path.getmtime(f)) < LIVE:
                return True
        except Exception:
            pass
    return False

cur = {}
hits = []
def flush(c):
    if c.get("path") and is_conv(c["path"]) and live_owner(os.path.realpath(c["path"])):
        hits.append(os.path.basename(c["path"]) + (f" [{c['branch']}]" if c.get("branch") else ""))
for line in wtlist.splitlines():
    if line.startswith("worktree "):
        flush(cur); cur = {"path": line[9:]}
    elif line.startswith("branch "):
        ref = line[7:]; cur["branch"] = ref[11:] if ref.startswith("refs/heads/") else ref
flush(cur)
print("; ".join(hits))
PY
)
LIVE_WT=$(printf '%s' "$LIVE_WT" | tr -d '\n')
[ -z "$LIVE_WT" ] && exit 0   # no live worktree was handed out — nothing to bypass

MSG_HDR="committing on '$BRANCH' in the PRIMARY checkout while a live session worktree exists: $LIVE_WT"
REMEDY="That worktree is where this work belongs — commit there, then PR -> $BRANCH (and FF main at ship). The primary checkout is the integration/ship lane, not a feature-work lane."

if [ "${WORKTREE_BYPASS_ENFORCE:-0}" = 1 ]; then
  echo >&2
  echo "BLOCKED [worktree-bypass]: $MSG_HDR" >&2
  echo "  $TOP" >&2
  echo "$REMEDY" >&2
  echo "If this IS the ship/coordinator committing intentionally: WORKTREE_BYPASS_OK=1 git commit ..." >&2
  echo >&2
  exit 1
fi

echo >&2
echo "⚠️  WORKTREE BYPASS [warn]: $MSG_HDR" >&2
echo "$REMEDY" >&2
echo "(warning only — allowed. Hard-block: WORKTREE_BYPASS_ENFORCE=1. Silence: WORKTREE_BYPASS_OK=1.)" >&2
echo >&2
exit 0
WTBYPASS
  chmod +x "$FRAG"
  GCD=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || echo "$ROOT/.git")
  case "$GCD" in /*) : ;; *) GCD="$ROOT/$GCD" ;; esac   # absolutize a relative git-common-dir
  EXCL="$GCD/info/exclude"
  if [ -f "$EXCL" ] && ! grep -qxF "scripts/githooks/pre-commit.d/30-worktree-bypass" "$EXCL" 2>/dev/null; then
    printf '\n# worktree-bypass guard — local, dropped by new-session.sh (not committed/shared)\nscripts/githooks/pre-commit.d/30-worktree-bypass\n' >> "$EXCL"
  fi
  echo "new-session: dropped worktree-bypass guard into the primary checkout's pre-commit.d (local, warn-only)"
fi

# Heavy lifting (worktree + env copy + deps) is session-worktree.sh's job.
# No --ref: session-worktree.sh resolves the SAME integration branch itself
# (via resolve_base_ref), so this script stays repo-agnostic.
# On failure, release the slug claim (delete origin/<slug>) so the slug isn't
# orphan-locked by a half-built session.
release_claim() {
  git push origin ":refs/heads/$slug" >/dev/null 2>&1 || true
  echo "new-session: released claim origin/$slug" >&2
}
if ! out=$(bash "$ROOT/scripts/session-worktree.sh" "$slug" --link-deps); then
  printf '%s\n' "$out" >&2
  release_claim
  echo "new-session: worktree setup failed" >&2
  exit 1
fi
dest=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE: //p' | tail -1)
if [ -z "$dest" ]; then
  printf '%s\n' "$out" >&2
  release_claim
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
