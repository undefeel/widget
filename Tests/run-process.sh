#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
swiftc -swift-version 5 -parse-as-library Sources/Shared/Models.swift Sources/App/Fetchers.swift Tests/ProcessHarness.swift -o "$tmp/process-harness"
"$tmp/process-harness"
