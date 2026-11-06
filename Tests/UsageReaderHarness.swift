import Foundation
import SQLite3

@main
struct UsageReaderHarness {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try checksWALVisibility(in: root)
        try opensLiteralFilename(in: root)
        try handlesMissingFile(in: root)
        try handlesBusyDatabase(in: root)
        print("UsageReader WAL, literal-path, missing-file and busy-lock checks passed.")
    }

    private static func checksWALVisibility(in root: URL) throws {
        let url = root.appendingPathComponent("wal.db")
        let writer = try open(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { sqlite3_close(writer) }
        try exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE records(payload BLOB);")
        try exec(writer, "INSERT INTO records VALUES (X'01');")
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        guard sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_FULL, &logFrames, &checkpointedFrames) == SQLITE_OK else {
            throw failure("checkpoint fixture")
        }
        try exec(writer, "INSERT INTO records VALUES (X'02');")
        guard (try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")))?.isEmpty == false else {
            throw failure("fixture did not retain WAL frames")
        }

        let production = try readRows(SQLiteReader(url))
        guard production == 2 else { throw failure("production reader saw \(production) rows; expected 2 including WAL") }

        var immutable: OpaquePointer?
        let uri = url.absoluteString + "?immutable=1"
        guard sqlite3_open_v2(uri, &immutable, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let immutable else {
            sqlite3_close(immutable)
            throw failure("open immutable comparison")
        }
        defer { sqlite3_close(immutable) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(immutable, "SELECT payload FROM records", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure("prepare immutable comparison") }
        defer { sqlite3_finalize(statement) }
        var immutableRows = 0
        while sqlite3_step(statement) == SQLITE_ROW { immutableRows += 1 }
        guard immutableRows == 1 else { throw failure("immutable fixture saw \(immutableRows) rows; expected checkpointed row only") }
    }

    private static func opensLiteralFilename(in root: URL) throws {
        let url = root.appendingPathComponent("literal ? # space π.db")
        let writer = try open(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try exec(writer, "CREATE TABLE records(payload BLOB); INSERT INTO records VALUES (X'2A');")
        sqlite3_close(writer)
        let rows = try readRows(SQLiteReader(url))
        guard rows == 1 else { throw failure("literal filename reader saw \(rows) rows") }
    }

    private static func handlesMissingFile(in root: URL) throws {
        let url = root.appendingPathComponent("missing.db")
        guard SQLiteReader(url) == nil else { throw failure("missing database unexpectedly opened") }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw failure("missing database was created") }
    }

    private static func handlesBusyDatabase(in root: URL) throws {
        let url = root.appendingPathComponent("busy.db")
        let setup = try open(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try exec(setup, "CREATE TABLE records(payload BLOB); INSERT INTO records VALUES (X'01');")
        sqlite3_close(setup)

        let writer = try open(url, flags: SQLITE_OPEN_READWRITE)
        defer {
            try? exec(writer, "ROLLBACK;")
            sqlite3_close(writer)
        }
        try exec(writer, "BEGIN EXCLUSIVE;")
        let started = Date()
        let reader = SQLiteReader(url)
        var rows = 0
        reader?.each("SELECT payload FROM records") { _ in rows += 1 }
        let elapsed = Date().timeIntervalSince(started)
        guard rows == 0 else { throw failure("busy source unexpectedly returned rows") }
        guard elapsed < 3 else { throw failure("busy read exceeded bounded wait: \(elapsed)s") }
        try exec(writer, "ROLLBACK;")
        let verify = try open(url, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(verify) }
        guard try scalar(verify, "SELECT count(*) FROM records") == 1 else {
            throw failure("busy read changed source application rows")
        }
    }

    private static func readRows(_ reader: SQLiteReader?) throws -> Int {
        guard let reader else { throw failure("production reader failed to open database") }
        var count = 0
        reader.each("SELECT payload FROM records") { _ in count += 1 }
        return count
    }

    private static func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw failure("open \(url.lastPathComponent)")
        }
        return db
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(message)
            throw failure("SQLite: \(detail)")
        }
    }

    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure("prepare scalar")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure("step scalar") }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "UsageReaderHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
