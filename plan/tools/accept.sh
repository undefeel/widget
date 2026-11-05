#!/usr/bin/env bash
# Full project acceptance; never installs or launches the application.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if [[ $# -gt 1 || (${1:-} != '' && ${1:-} != '--tools-only') ]]; then
  echo 'Usage: accept.sh [--tools-only]' >&2
  exit 2
fi
LOG="$(mktemp -t widget-accept.XXXXXX)"
trap 'rm -f "$LOG"' EXIT
check() {
  local result=0
  "$@" >"$LOG" 2>&1 || result=$?
  tail -40 "$LOG"
  return "$result"
}
check git diff --check
check git diff --cached --check
for script in build.sh plan/tools/*.sh; do
  check bash -n "$script"
done
check python3 -m unittest discover -s plan/tools -p 'test_*.py'
if [[ ${1:-} == '--tools-only' ]]; then
  echo 'Portable tooling acceptance passed; macOS build was not requested.'
  exit 0
fi
if [[ $(uname -s) != Darwin ]]; then
  echo 'Full acceptance requires macOS Command Line Tools. Portable checks passed.' >&2
  exit 1
fi
for resource in Resources/*.plist Resources/*.entitlements Resources/*/*.strings; do
  check plutil -lint "$resource"
done
check ./build.sh
check codesign --verify --deep --strict build/AILimits.app
echo 'Full acceptance passed (universal app and widget; signatures verified).'
