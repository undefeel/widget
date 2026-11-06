#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t usage-reader.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$ROOT/Sources/App/Usage.swift" "$TMP/SQLiteReader.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index("/// Чтение SQLite-базы только для чтения.")
end = source.index("/// Минимальный разбор protobuf", start)
reader = source[start:end].replace("private final class SQLiteReader", "final class SQLiteReader", 1)
reader = reader.replace("sqlite3_close(db)", "trackedSQLiteClose(db)")
Path(sys.argv[2]).write_text("import Foundation\nimport SQLite3\n\n" + reader)
PY

swiftc -swift-version 5 "$TMP/SQLiteReader.swift" "$ROOT/Tests/UsageReaderHarness.swift" -o "$TMP/usage-reader"
"$TMP/usage-reader"
