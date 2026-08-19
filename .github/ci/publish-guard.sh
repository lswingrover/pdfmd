#!/usr/bin/env bash
# publish-guard.sh — CI file-tracking guard. FLEET-CANONICAL: single source lives in
# scotty/scripts/ci-templates/; each repo gets a vendored copy at .github/ci/publish-guard.sh
# via vendor-ci.sh. EDIT HERE and re-vendor — never hand-edit a per-repo copy (drift is the
# whole thing this replaces: uhura's and captains-log's hand-written guards had diverged).
#
# This is LAYER 1 of 3 (ci-reform plan §5). It asserts no secret-bearing FILE is tracked —
# structural, hermetic, runs anywhere. It does NOT scan file CONTENT:
#   - credential VALUES        -> gitleaks (githooks 10-secret-scan; can also run in CI)
#   - identifier LEAKS         -> the local 15-discreet-denylist hook, which stores no values
#                                 and fails open, so it is local-only BY DESIGN (never CI).
# Names no person or company — a structural check only, safe in a public repo.
set -euo pipefail

# Real secret/config files that must never be tracked; the *.example|sample|template
# siblings are allowed. `tokens.json` is matched both inside a tokens/ dir AND as a bare
# filename at any path (else a tracked config/tokens.json slips through). Keep this pattern
# equal to any inline copy; CANONICAL.sha256 + audit tooling detect drift.
bad=$(git ls-files \
  | grep -E '(^|/)\.env($|\.)|(^|/)accounts\.json$|(^|/)tokens/.*\.json$|(^|/)tokens\.json$|\.(pem|key|p12|mobileprovision)$' \
  | grep -vE '(^|/)\.env\.(example|sample|template)$' || true)

# Per-repo escape hatch: .github/ci/publish-guard-allow lists globs for VERIFIED-benign
# matches — e.g. a PUBLIC key that must be published (Tesla .well-known/*.pem). One glob per
# line; blank lines and #comments ignored. Strict-by-default with an explicit, auditable
# allowlist (mirrors the gitleaks .gitleaks.toml and the hooks' denylist:ignore philosophy).
ALLOW=".github/ci/publish-guard-allow"
if [ -n "$bad" ] && [ -f "$ALLOW" ]; then
  filtered=""
  while IFS= read -r path; do
    keep=1
    while IFS= read -r pat; do
      case "$pat" in ''|\#*) continue ;; esac
      # shellcheck disable=SC2254
      case "$path" in $pat) keep=0; break ;; esac
    done < "$ALLOW"
    [ "$keep" = 1 ] && filtered+="$path"$'\n'
  done <<EOF
$bad
EOF
  bad=$(printf '%s' "$filtered" | grep -v '^$' || true)
fi

if [ -n "$bad" ]; then
  echo "publish-guard: FAIL — files that must never be committed are tracked:" >&2
  echo "$bad" >&2
  echo "(if a match is a VERIFIED-benign public artifact, allowlist its glob in $ALLOW)" >&2
  exit 1
fi
echo "publish-guard: clean — no secrets or real config tracked."
