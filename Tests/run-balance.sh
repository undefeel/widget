#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BIN="$(mktemp -t ailimits-balance.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 5 -parse-as-library \
  Sources/Shared/Models.swift Sources/App/CheapVibe.swift Tests/BalanceHarness.swift \
  -o "$BIN"
"$BIN" "$@"
