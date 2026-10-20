#!/usr/bin/env bash
# Arm the canonical git hooks for THIS clone and every one of its worktrees (safe to re-run).
#
# core.hooksPath lives in the clone's SHARED config (.git/config), so one value governs
# every worktree at once. A RELATIVE value resolves inside each worktree separately: it
# arms a worktree whose branch carries the hooks dir and silently disarms one whose
# branch does not. Git does not fall back to the global hooks dir when a configured path
# is missing; it just runs no hooks. So this installer never writes a value without first
# checking what that value would do in every worktree:
#
#   kept     the current value already reaches an executable pre-commit in every
#            worktree, and CANONICAL.sha256 verifies in each hooks dir it reaches.
#            Nothing is written. This is what protects a deliberate absolute pin.
#   set      the relative value (scripts/githooks) is written only when every worktree
#            has an executable <worktree>/scripts/githooks/pre-commit.
#   refused  anything else: write nothing, name each worktree that would be left without
#            hooks, and print the recipe for pinning one stable absolute copy (--pin).
#            Exit 1 when some worktree has no hooks right now, else 3 (see Exit below).
#
# Hooks are composable dispatchers: pre-push / pre-commit run every executable in their
# *.d/ dir, so a repo adds its own checks (plugin-staleness, skill validation, ...) as a
# fragment without touching the universal base. The base is vendored (see
# scripts/vendor-githooks.sh), and scripts/githooks/CANONICAL.sha256 pins its bytes,
# including this installer and the other vendored helper scripts.
#
#   bash scripts/install-git-hooks.sh                  arm: kept, set, or refused
#   bash scripts/install-git-hooks.sh --check          report per worktree; write nothing
#   bash scripts/install-git-hooks.sh --pin <abs-dir>  validate a hooks dir, then point
#                                                      core.hooksPath at it (absolute)
#   bash scripts/install-git-hooks.sh --verify         check vendored base vs CANONICAL.sha256
#
# Exit (arm, --pin, --check alike):
#   0  every worktree runs the vendored set (after any write)
#   3  no worktree is without hooks, but not every one runs the vendored set (another
#      hooks dir such as a global fallback or an override, a manifest that does not
#      verify, or a worktree whose directory is missing and could not be checked).
#      Whatever was safe was written; nothing that would disarm a worktree was.
#   1  refused: some worktree has no hooks at all, now or after the write; nothing written
#   2  usage error
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/install-git-hooks.sh                  arm: kept, set, or refused
       bash scripts/install-git-hooks.sh --check          report per worktree; write nothing
       bash scripts/install-git-hooks.sh --pin <abs-dir>  validate, then pin core.hooksPath
       bash scripts/install-git-hooks.sh --verify         check vendored base vs CANONICAL.sha256
USAGE
  exit 2
}

ROOT=$(git rev-parse --show-toplevel)

# Standardize on scripts/githooks. Some older repos use scripts/hooks; both are supported,
# and the first that exists wins, so a repo can migrate without a flag day.
HOOKS_REL=""
for REL in scripts/githooks scripts/hooks; do
  [ -d "$ROOT/$REL" ] && { HOOKS_REL="$REL"; break; }
done

MODE="${1:-}"
PIN=""
case "$MODE" in
  "") MODE=arm ;;
  --check|--verify) ;;
  --pin) PIN="${2:-}"; [ -n "$PIN" ] || usage ;;
  *) usage ;;
esac

# Only --verify needs this worktree's own copy. Everything else can run from a worktree
# whose branch has no hooks dir: a value that already arms every worktree is still kept,
# and writing the relative value is refused there by the same per-worktree check that
# refuses it anywhere else (this worktree is one of the ones it would leave hookless).
if [ -z "$HOOKS_REL" ]; then
  [ "$MODE" = "--verify" ] && { echo "install-git-hooks: no scripts/githooks or scripts/hooks dir in this worktree ($ROOT)" >&2; exit 1; }
  HOOKS_REL=scripts/githooks
fi
DIR="$ROOT/$HOOKS_REL"

if [ "$MODE" = "--verify" ]; then
  [ -f "$DIR/CANONICAL.sha256" ] || { echo "no $HOOKS_REL/CANONICAL.sha256 to verify against" >&2; exit 1; }
  ( cd "$DIR" && shasum -a 256 -c CANONICAL.sha256 )
  exit $?
fi

if [ "$MODE" != "--check" ] && [ -d "$DIR" ]; then
  chmod +x "$DIR"/* 2>/dev/null || true
  chmod +x "$DIR"/*.d/* 2>/dev/null || true
fi

TAB=$(printf '\t')
# --show-scope tells a worktree-scoped override (which a shared write cannot change)
# apart from the shared value. Older git lacks it; then every value is treated as shared.
SCOPED=1
git config --show-scope --list >/dev/null 2>&1 || SCOPED=0

# ── Which worktrees ────────────────────────────────────────────────────────────────
# Every record git keeps, except the bare entry. A record whose directory is missing
# cannot be checked: a locked worktree on an unmounted drive comes back running whatever
# the value says, and a "prunable" record is either deleted (git worktree prune clears
# it) or MOVED by hand (git worktree repair <new-path> fixes it; until then this script
# cannot find it). Each is listed and keeps the verdict at 3 rather than 0. The worktree
# this runs in is always included: one moved by hand is not where git's record says, but
# git still runs hooks there.
listed() {
  git worktree list --porcelain | awk '
    function emit() { if (p != "" && !bare) print p }
    /^worktree / { emit(); p = substr($0, 10); bare = 0; next }
    /^bare$/ { bare = 1 }
    END { emit() }'
}
phys() { ( cd "$1" 2>/dev/null && pwd -P ); }
ROOT_P=$(phys "$ROOT")
WTS=""; MISSING=""; MAIN_WT=""; seen_root=0
NL='
'
while IFS= read -r w; do
  [ -n "$w" ] || continue
  [ -n "$MAIN_WT" ] || MAIN_WT="$w"
  if [ -d "$w" ]; then
    WTS="$WTS$w$NL"
    [ "$(phys "$w")" = "$ROOT_P" ] && seen_root=1
  else
    MISSING="$MISSING$NL    $w  (directory missing; not checked. Deleted: git worktree prune. Moved: git worktree repair <new-path>)"
  fi
done <<EOF
$(listed)
EOF
[ "$seen_root" = 1 ] || WTS="$ROOT$NL$WTS"
[ -n "$MAIN_WT" ] || MAIN_WT="$ROOT"

# resolve <worktree> <value>: the directory git runs hooks from in that worktree.
# A relative value is relative to the worktree's top level (git runs hooks from there);
# "~/" is expanded the way git expands a path-valued config key; no value means the
# default hooks dir inside the clone's common git dir.
resolve() {
  _v="$2"
  if [ -z "$_v" ]; then
    _c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || _c="$1/.git"
    printf '%s/hooks\n' "$_c"; return
  fi
  case "$_v" in "~") _v="$HOME" ;; "~/"*) _v="$HOME/${_v#\~/}" ;; esac
  case "$_v" in /*) printf '%s\n' "${_v%/}" ;; *) printf '%s/%s\n' "$1" "${_v%/}" ;; esac
}

# scope_and_value <worktree>: prints "<scope><TAB><value>" for core.hooksPath as that
# worktree sees it ("" for both when unset).
scope_and_value() {
  if [ "$SCOPED" = 1 ]; then
    git -C "$1" config --show-scope --get core.hooksPath 2>/dev/null || printf '%s\n' "$TAB"
  else
    _x=$(git -C "$1" config --get core.hooksPath 2>/dev/null) || _x=""
    printf 'local%s%s\n' "$TAB" "$_x"
  fi
}

has_pre_commit() { [ -f "$1/pre-commit" ] && [ -x "$1/pre-commit" ]; }
# has_any_hook <dir>: git would run at least one hook from it (commit-msg alone counts).
has_any_hook() {
  for _h in pre-commit commit-msg prepare-commit-msg pre-merge-commit pre-push post-commit \
            pre-rebase post-checkout post-merge post-rewrite reference-transaction; do
    [ -f "$1/$_h" ] && [ -x "$1/$_h" ] && return 0
  done
  return 1
}

# integrity <dir>: ok (CANONICAL.sha256 verifies), none (no manifest: not the vendored
# set), or fail (manifest present, bytes differ). A failure is reported, never blessed:
# it rules out "kept", but it does not stop the relative value from being written when
# every worktree has hooks, because a worktree mid-way through editing a hook (before its
# manifest is regenerated) is ordinary development, not a reason to leave others unarmed.
integrity() {
  [ -f "$1/CANONICAL.sha256" ] || { echo none; return; }
  if ( cd "$1" && shasum -a 256 -c --status CANONICAL.sha256 ) >/dev/null 2>&1; then echo ok; else echo fail; fi
}

# classify <dir>: vendored | other | fail | none (no hooks at all)
classify() {
  if has_pre_commit "$1"; then
    case "$(integrity "$1")" in ok) echo vendored ;; fail) echo fail ;; *) echo other ;; esac
  elif has_any_hook "$1"; then echo other
  else echo none
  fi
}
label() {
  case "$1" in
    vendored) echo "armed (vendored set)" ;;
    other)    echo "runs another hooks dir (not the vendored set)" ;;
    fail)     echo "armed, but its CANONICAL.sha256 does NOT verify" ;;
    none)     echo "NO HOOKS AT ALL" ;;
  esac
}

# ── Evaluate every worktree now, and under the candidate value ───────────────────────
# The candidate is the relative path, or the --pin target. A worktree-scoped override
# wins over the shared value, so under the candidate that worktree keeps its override.
CAND="$HOOKS_REL"
if [ -n "$PIN" ]; then
  case "$PIN" in /*) ;; *) echo "install-git-hooks: --pin needs an absolute path (got '$PIN')" >&2; exit 1 ;; esac
  PIN="${PIN%/}"
  CAND="$PIN"
fi

n=0; report=""
now_none=""; now_degraded=""; now_fail=""   # current state
cand_none=""; after_degraded=""             # under the candidate
while IFS= read -r w; do
  [ -n "$w" ] || continue
  n=$((n+1))
  sv=$(scope_and_value "$w")
  scope="${sv%%"$TAB"*}"; val="${sv#*"$TAB"}"
  cur=$(resolve "$w" "$val")
  c=$(classify "$cur")
  case "$c" in
    none) now_none="$now_none$NL    $w" ;;
    other) now_degraded="$now_degraded$NL    $w  (runs $cur)" ;;
    fail) now_degraded="$now_degraded$NL    $w  ($cur fails CANONICAL.sha256)"
          case "$now_fail$NL" in *"$NL    $cur$NL"*) ;; *) now_fail="$now_fail$NL    $cur" ;; esac ;;
  esac
  if [ "$scope" = "worktree" ]; then
    after="$cur"; a="$c"; note="  [worktree-scoped override: $val]"
  else
    after=$(resolve "$w" "$CAND"); a=$(classify "$after"); note=""
  fi
  # The relative value is written only where every worktree gets a pre-commit from it;
  # an override that keeps some other armed dir does not block it.
  if [ "$scope" = "worktree" ]; then
    [ "$a" = none ] && cand_none="$cand_none$NL    $w  (its own override reaches no hooks: $after)$note"
  else
    has_pre_commit "$after" || cand_none="$cand_none$NL    $w  (no executable $after/pre-commit)"
  fi
  case "$a" in
    other) after_degraded="$after_degraded$NL    $w  (runs $after)$note" ;;
    fail)  after_degraded="$after_degraded$NL    $w  ($after fails CANONICAL.sha256)$note" ;;
  esac
  shown="${val:-<unset>}"; [ "$cur" = "$val" ] || shown="$shown -> $cur"
  report="$report$NL  $w$NL      $shown  $(label "$c")$note"
done <<EOF
$WTS
EOF

# A STALE PIN: a hooks dir outside the worktree it serves (one absolute copy that every
# worktree reaches) still verifies against its OWN manifest when it falls behind, so it
# looks healthy while every worktree runs old hooks. When this worktree carries its own
# vendored set and the pinned copy's manifest differs from it, say so. It is a warning
# (exit 3), never a reason to replace the pin. Judged on the value that will be IN USE:
# the current one for --check and a keep, the candidate for a write (--pin, or set), where
# a worktree-scoped override keeps its own value.
# stale_pins_for <now|after>
stale_pins_for() {
  _out=""
  [ -f "$DIR/CANONICAL.sha256" ] || return 0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    sv=$(scope_and_value "$w"); scope="${sv%%"$TAB"*}"; val="${sv#*"$TAB"}"
    if [ "$1" = after ] && [ "$scope" != worktree ]; then val="$CAND"; fi
    [ -n "$val" ] || continue
    d=$(resolve "$w" "$val")
    case "$d/" in "$w"/*) continue ;; esac
    [ -f "$d/CANONICAL.sha256" ] || continue
    [ "$(phys "$d")" = "$(phys "$DIR")" ] && continue
    cmp -s "$d/CANONICAL.sha256" "$DIR/CANONICAL.sha256" && continue
    case "$_out$NL" in *"$NL    $d "*) ;; *) _out="$_out$NL    $d  (its manifest differs from $DIR. If the pinned copy is behind, refresh the checkout that holds it: git -C <hooks-worktree> fetch origin && git -C <hooks-worktree> checkout --detach origin/<default-branch>. If THIS checkout is behind, pull it.)" ;; esac
  done <<EOF
$WTS
EOF
  printf '%s' "$_out"
}
stale_pins=$(stale_pins_for now)

# The SHARED value is the one this script writes and may replace; the effective value is
# what this worktree actually sees (it may come from global config, or an override).
shared_value=$(git -C "$ROOT" config --local --get core.hooksPath 2>/dev/null || true)
effective_value=$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)

print_report() {
  printf '%s\n' "core.hooksPath across $n worktree(s) of this clone:$report" >&2
  [ -z "$MISSING" ] || printf '%s\n' "  not checked:$MISSING" >&2
}
warn_fail() {
  [ -n "$now_fail" ] || return 0
  echo "install-git-hooks: WARNING: a live hooks dir fails its CANONICAL.sha256:$now_fail" >&2
  echo "  inspect with: (cd <dir> && shasum -a 256 -c CANONICAL.sha256)" >&2
}
# finish <ok-message>: after a write (or a keep), exit 0 only when every worktree runs
# the vendored set and none went unchecked; otherwise say which, and exit 3.
finish() {
  if [ -z "$after_degraded" ] && [ -z "$MISSING" ] && [ -z "$stale_pins" ]; then
    echo "$1; vendored set in all $n worktree(s))"
    exit 0
  fi
  echo "$1; no worktree is without hooks)"
  [ -z "$after_degraded" ] || echo "install-git-hooks: note: not running the vendored set:$after_degraded" >&2
  [ -z "$stale_pins" ] || echo "install-git-hooks: note: the pinned hooks copy is not this checkout's vendored set:$stale_pins" >&2
  [ -z "$MISSING" ] || echo "install-git-hooks: note: not checked:$MISSING" >&2
  exit 3
}

# Recipe for one stable absolute copy that every worktree can reach.
print_recipe() {
  hooks_wt="$(dirname "$MAIN_WT")/$(basename "$MAIN_WT")-hooks"
  base=$(git -C "$ROOT" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  cat >&2 <<RECIPE

To arm every worktree at once, point core.hooksPath at ONE copy of the hooks by absolute
path, kept in a detached worktree of $base that nobody works in:

RECIPE
  if [ -d "$hooks_wt" ]; then
    echo "  git -C \"$hooks_wt\" fetch origin && git -C \"$hooks_wt\" checkout --detach $base   # refresh the existing copy first" >&2
  else
    echo "  git worktree add --detach \"$hooks_wt\" $base" >&2
  fi
  cat >&2 <<RECIPE
  bash scripts/install-git-hooks.sh --pin "$hooks_wt/$HOOKS_REL"

After hook changes merge, refresh that copy:
  git -C "$hooks_wt" fetch origin && git -C "$hooks_wt" checkout --detach $base

Or bring the listed worktrees up to date so their branches carry $HOOKS_REL/, or
remove the ones nobody needs (git worktree remove <path>), then re-run this script.
RECIPE
}

warn_fail

if [ "$MODE" = "--check" ]; then
  print_report
  if [ -n "$now_none" ]; then
    echo "install-git-hooks: NO HOOKS AT ALL in:$now_none" >&2; exit 1
  fi
  if [ -z "$now_degraded" ] && [ -z "$MISSING" ] && [ -z "$stale_pins" ]; then
    echo "install-git-hooks: vendored set armed in all $n worktree(s)."; exit 0
  fi
  [ -z "$now_degraded" ] || echo "install-git-hooks: every worktree has hooks, but not the verified vendored set in:$now_degraded" >&2
  [ -z "$stale_pins" ] || echo "install-git-hooks: the pinned hooks copy is not this checkout's vendored set:$stale_pins" >&2
  [ -z "$MISSING" ] || echo "install-git-hooks: not checked:$MISSING" >&2
  exit 3
fi

if [ -n "$PIN" ]; then
  [ -d "$PIN" ] || { echo "install-git-hooks: --pin target is not a directory: $PIN" >&2; exit 1; }
  has_pre_commit "$PIN" || { echo "install-git-hooks: --pin target has no executable pre-commit: $PIN" >&2; exit 1; }
  case "$(integrity "$PIN")" in
    ok) ;;
    none) echo "install-git-hooks: --pin target has no CANONICAL.sha256, so it is not a vendored hooks set: $PIN" >&2; exit 1 ;;
    fail) echo "install-git-hooks: --pin target fails CANONICAL.sha256: $PIN" >&2; exit 1 ;;
  esac
  if [ -n "$cand_none" ]; then
    print_report
    echo "install-git-hooks: REFUSED. These worktrees would still run no hooks after the pin:$cand_none" >&2
    echo "  a worktree-scoped override wins over the shared value; remove it with:" >&2
    echo "    git -C <worktree> config --worktree --unset core.hooksPath" >&2
    exit 1
  fi
  # A pin inside a worktree that has a branch checked out moves whenever someone commits
  # or switches branches there. Allowed, but say so.
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    case "$PIN/" in "$w"/*)
      if git -C "$w" symbolic-ref -q HEAD >/dev/null 2>&1; then
        echo "install-git-hooks: note: $PIN is inside $w, which has a branch checked out; its hooks change whenever that branch does. A detached worktree nobody works in is steadier." >&2
      fi ;;
    esac
  done <<EOF
$WTS
EOF
  stale_pins=$(stale_pins_for after)
  if [ "$shared_value" = "$PIN" ]; then
    finish "core.hooksPath = $PIN  (kept: already pinned"
  fi
  git -C "$ROOT" config --local core.hooksPath "$PIN"
  finish "core.hooksPath = $PIN  (pinned; was ${shared_value:-<unset>}"
fi

if [ -z "$now_none" ] && [ -z "$now_degraded" ]; then
  after_degraded=""   # keeping: the state after is the state now
  finish "core.hooksPath = ${effective_value:-<unset>}  (kept: already armed"
fi

if [ -z "$cand_none" ]; then
  stale_pins=$(stale_pins_for after)
  if [ "$shared_value" = "$HOOKS_REL" ]; then
    finish "core.hooksPath = $HOOKS_REL  (kept: every worktree has $HOOKS_REL/pre-commit"
  fi
  git -C "$ROOT" config --local core.hooksPath "$HOOKS_REL"
  if [ -n "$shared_value" ]; then
    finish "core.hooksPath = $HOOKS_REL  (set; REPLACED $shared_value"
  fi
  finish "core.hooksPath = $HOOKS_REL  (set"
fi

print_report
echo "install-git-hooks: REFUSED. Writing core.hooksPath=$HOOKS_REL would leave these worktrees with NO hooks:$cand_none" >&2
echo "  shared value (${shared_value:-<unset>}) left unchanged." >&2
print_recipe
if [ -n "$now_none" ]; then
  echo "install-git-hooks: and these worktrees have NO HOOKS AT ALL right now:$now_none" >&2
  exit 1
fi
echo "install-git-hooks: nothing is without hooks right now (every worktree runs some hooks dir), so this is a warning, not an outage." >&2
exit 3
