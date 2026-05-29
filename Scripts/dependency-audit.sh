#!/usr/bin/env bash
# Dependency CVE audit for SwiftPM pins, against the OSV.dev advisory database.
#
# Why a custom script rather than osv-scanner: osv-scanner (2.3.x) has no
# Package.resolved extractor, and OSV's Swift advisory records are inconsistent
# about the package name (some store the bare repo name, e.g. "swift-crypto";
# others the full "github.com/owner/repo"). To avoid false negatives we query the
# OSV API directly for BOTH name forms and union the results. OSV mirrors the
# GitHub Advisory Database, which carries Swift (SwiftURL) advisories.
#
# Usage: Scripts/dependency-audit.sh [Package.resolved]
# Exit 1 if any pinned version has a matching advisory. Requires: jq, curl, and a
# resolved Package.resolved (run `swift package resolve` first).
set -euo pipefail

resolved="${1:-Package.resolved}"
if [ ! -f "$resolved" ]; then
  echo "::error::$resolved not found (run 'swift package resolve' first)"
  exit 1
fi

fail=0
while IFS=$'\t' read -r url ver; do
  [ -n "$ver" ] || continue # skip branch/revision pins (no semver to match)
  repo=$(basename "$url" .git)
  short=$(printf '%s' "$url" | sed -E 's#^https?://##; s#\.git$##')
  ids=""
  for name in "$repo" "$short"; do
    found=$(curl -fsS --max-time 25 -X POST "https://api.osv.dev/v1/query" \
      -d "{\"version\":\"$ver\",\"package\":{\"ecosystem\":\"SwiftURL\",\"name\":\"$name\"}}" 2>/dev/null \
      | jq -r '.vulns[]?.id' 2>/dev/null || true)
    [ -n "$found" ] && ids="$ids $found"
  done
  ids=$(printf '%s' "$ids" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ *$//')
  if [ -n "$ids" ]; then
    echo "::error::$repo $ver has advisories: $ids"
    fail=1
  else
    echo "ok: $repo $ver"
  fi
done < <(jq -r '.pins[] | select(.state.version != null) | "\(.location)\t\(.state.version)"' "$resolved")

if [ "$fail" -ne 0 ]; then
  echo "::error::Vulnerable dependency pin(s) found. Bump the pin past the fix, or document an accepted risk."
fi
exit $fail
