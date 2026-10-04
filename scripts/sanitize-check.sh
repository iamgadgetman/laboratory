#!/usr/bin/env bash
# Fail if anything that looks like real lab detail is present.
# Usage: scripts/sanitize-check.sh   (run from repo root)
set -u
patterns=(
  '10\.0\.[0-9]+\.[0-9]+'          # real lab ranges
  '10\.2\.(2|100)\.'               # real WG ranges
  '192\.168\.[0-9]+\.[0-9]+'
  '172\.(1[6-9]|2[0-9]|3[01])\.'
  'galaxy\.rip'
  'gadgetman\.cloud'
  '(ghp|gho|github_pat)_[A-Za-z0-9]{20,}'
  'eyJ[A-Za-z0-9_-]{20,}\.'        # JWT
  '-----BEGIN [A-Z ]*PRIVATE KEY'
  '[A-Za-z0-9+/]{43}='             # WireGuard key shape
)
rc=0
for p in "${patterns[@]}"; do
  if grep -rnIE --exclude-dir=.git --exclude=sanitize-check.sh -- "$p" . ; then
    echo ">>> matched: $p" >&2; rc=1
  fi
done
# Fail on any public IPv4 that is not RFC 5737 documentation space.
grep -rnIoE --exclude-dir=.git --exclude=sanitize-check.sh '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' . \
  | grep -vE ':(10\.|127\.|0\.0\.0\.0|1\.1\.1\.1|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|255\.)' \
  | grep -vE ':[0-9]+\.[0-9]+\.[0-9]+:' && { echo ">>> non-documentation public IP found" >&2; rc=1; }
[ $rc -eq 0 ] && echo "sanitize-check: clean"
exit $rc
