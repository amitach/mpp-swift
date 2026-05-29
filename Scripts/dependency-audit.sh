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
# This gate FAILS CLOSED: a parse error, an empty pin set, or an OSV/network
# failure exits non-zero (it never silently passes having checked nothing).
#
# Usage: Scripts/dependency-audit.sh [Package.resolved]
# Exit 0 = all pins clean; 1 = an advisory matched a pin; 2 = the audit could not
# run (parse/network/API failure). Requires: jq, curl, a resolved Package.resolved.
set -euo pipefail

resolved="${1:-Package.resolved}"
if [ ! -f "$resolved" ]; then
  echo "::error::$resolved not found (run 'swift package resolve' first); failing closed"
  exit 2
fi

# Parse pins up front. Fail CLOSED if jq cannot parse the lockfile (a schema
# change or parse error must never make the gate silently pass), and if no
# versioned pins are found (this package always has dependencies).
if ! pins="$(jq -r '.pins[] | select(.state.version != null) | "\(.location)\t\(.state.version)"' "$resolved")"; then
  echo "::error::could not parse $resolved (jq failed); failing closed"
  exit 2
fi
if [ -z "$pins" ]; then
  echo "::error::no versioned pins found in $resolved (unexpected); failing closed"
  exit 2
fi
# A branch/revision pin has no semantic version, so OSV cannot range-match it.
# Fail CLOSED rather than silently skip it (an un-scanned dependency must never
# pass the gate unnoticed).
revpins="$(jq -r '.pins[] | select(.state.version == null) | .location' "$resolved")" || {
  echo "::error::could not parse $resolved for revision pins; failing closed"
  exit 2
}
if [ -n "$revpins" ]; then
  echo "::error::revision/branch-pinned dependencies cannot be OSV version-scanned: $revpins"
  echo "::error::pin them to a released version, or scan them out of band; failing closed"
  exit 2
fi

# Query OSV for one (name, version). Prints advisory ids on stdout. Returns
# non-zero on ANY query failure (curl error after retries, or a non-JSON body),
# so the caller fails closed instead of treating an unreachable OSV as "safe".
query_osv() {
  local name="$1" ver="$2" resp body
  # Build the JSON body with jq (not string interpolation), so a name/version is
  # always correctly escaped and cannot inject into the request body.
  body="$(jq -nc --arg v "$ver" --arg n "$name" \
    '{version: $v, package: {ecosystem: "SwiftURL", name: $n}}')"
  if ! resp="$(curl -fsS --retry 3 --retry-delay 2 --max-time 30 \
      -H "Content-Type: application/json" \
      -X POST "https://api.osv.dev/v1/query" --data "$body")"; then
    return 1
  fi
  # A successful OSV query returns a JSON object ({} when no vulns, or
  # {"vulns":[...]}). Anything else is a failed query.
  printf '%s' "$resp" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  printf '%s' "$resp" | jq -r '.vulns[]?.id'
}

fail=0
while IFS=$'\t' read -r url ver; do
  [ -n "$ver" ] || continue
  repo=$(basename "$url" .git)
  short=$(printf '%s' "$url" | sed -E 's#^https?://##; s#\.git$##')
  ids=""
  for name in "$repo" "$short"; do
    if ! out="$(query_osv "$name" "$ver")"; then
      echo "::error::OSV query failed for $name@$ver (network/API); failing closed"
      exit 2
    fi
    [ -n "$out" ] && ids="$ids $out"
  done
  ids=$(printf '%s' "$ids" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ *$//')
  if [ -n "$ids" ]; then
    echo "::error::$repo $ver has advisories: $ids"
    fail=1
  else
    echo "ok: $repo $ver"
  fi
done <<< "$pins"

if [ "$fail" -ne 0 ]; then
  echo "::error::Vulnerable dependency pin(s) found. Bump the pin past the fix, or document an accepted risk."
fi
exit "$fail"
