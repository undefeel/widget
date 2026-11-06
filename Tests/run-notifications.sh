#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Notification checks require macOS Swift frameworks" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
swiftc -swift-version 5 -O -parse-as-library \
  Sources/Shared/Models.swift Sources/App/Fetchers.swift Sources/App/Services.swift \
  Tests/NotificationTests.swift -o "$tmp/notification-tests"
"$tmp/notification-tests"
