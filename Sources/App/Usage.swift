import Foundation
import SQLite3

/// Токены по дням за текущую и 4 прошлые календарные недели по локальным логам Claude Code, Codex и Antigravity.
/// Считаются вход + запись в кэш + выход; чтение из кэша не учитывается, иначе оно забивает всё остальное.
enum UsageScanner {
    typealias Adder = (_ model: String, _ provider: Provider, _ date: Date, _ tokens: Int, _ session: String) -> Void

    static func scan(now: Date = Date()) -> UsageStats {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = cal.date(byAdding: .day, value: -28, to: weekStart) ?? weekStart
        let count = (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        let dayStarts = (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: start) }

        var buckets: [String: (provider: Provider, days: [Int], sessions: Set<String>, week: Set<String>)] = [:]
        var todaySessions = Set<String>()
        func add(_ raw: String, _ provider: Provider, _ date: Date, _ tokens: Int, _ session: String) {
            guard tokens > 0, date >= start else { return }
            let i = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: date)).day ?? -1
            guard dayStarts.indices.contains(i) else { return }
            // Одна и та же модель у разных агентов (Claude в Antigravity) — разные строки.
            let key = provider.rawValue + "|" + Fmt.modelName(raw)
            var b = buckets[key] ?? (provider, Array(repeating: 0, count: dayStarts.count), [], [])
            b.days[i] += tokens
            b.sessions.insert(session)
            if i >= dayStarts.count - 7 { b.week.insert(session) }
            buckets[key] = b
            if i == dayStarts.count - 1 { todaySessions.insert(session) }
        }
        scanClaude(since: start, add)
        scanCodex(since: start, add)
        scanAntigravity(since: start, add)

        let models = buckets
            .map { ModelUsage(model: String($0.key.split(separator: "|", maxSplits: 1).last ?? ""), provider: $0.value.provider, days: $0.value.days,
                              sessions: $0.value.week.count, sessionsMonth: $0.value.sessions.count) }
            .sorted { $0.days.reduce(0, +) > $1.days.reduce(0, +) }
        return UsageStats(dayStarts: dayStarts, models: models, sessionsToday: todaySessions.count, generatedAt: now)
    }

    // MARK: Claude Code: ~/.claude/projects/**/*.jsonl

    private static func scanClaude(since: Date, _ add: Adder) {
        let root = SnapshotIO.realHome.appendingPathComponent(".claude/projects")
        var seen = Set<String>()
        for file in files(under: root, since: since) {
            lines(file, containing: ["\"usage\""]) { o in
                guard o["type"] as? String == "assistant",
                      let msg = o["message"] as? [String: Any],
                      let model = msg["model"] as? String, !model.hasPrefix("<"),
                      let u = msg["usage"] as? [String: Any],
                      let date = J.date(o["timestamp"]) else { return }
                // Один ответ пишется несколькими строками с одинаковым usage.
                let key = (msg["id"] as? String).map { $0 + ":" + (o["requestId"] as? String ?? "") }
                    ?? (o["uuid"] as? String ?? UUID().uuidString)
                guard seen.insert(key).inserted else { return }
                let tokens = ["input_tokens", "cache_creation_input_tokens", "output_tokens"]
                    .reduce(0) { $0 + Int(J.num(u[$1]) ?? 0) }
                add(model, .claude, date, tokens, o["sessionId"] as? String ?? file.lastPathComponent)
            }
        }
    }

    // MARK: Codex: ~/.codex/sessions/**/*.jsonl

    private static func scanCodex(since: Date, _ add: Adder) {
        let root = SnapshotIO.realHome.appendingPathComponent(".codex/sessions")
        for file in files(under: root, since: since) {
            var model = "codex"
            var prev = 0
            lines(file, containing: ["turn_context", "token_count"]) { o in
                guard let p = o["payload"] as? [String: Any] else { return }
                if o["type"] as? String == "turn_context" {
                    if let m = p["model"] as? String { model = m }
                    return
                }
                guard p["type"] as? String == "token_count",
                      let info = p["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let date = J.date(o["timestamp"]) else { return }
                // total_token_usage растёт за сессию; берём прирост. Кэшированный вход входит в input_tokens.
                let input = Int(J.num(total["input_tokens"]) ?? 0)
                let cached = Int(J.num(total["cached_input_tokens"]) ?? 0)
                let sum = max(0, input - cached) + Int(J.num(total["output_tokens"]) ?? 0)
                if sum > prev { add(model, .codex, date, sum - prev, file.lastPathComponent) }
                prev = max(prev, sum)
            }
        }
    }

    // MARK: Antigravity: ~/.gemini/antigravity{-cli,}/conversations/*.db

    /// Каждый разговор — SQLite. Токены и время — из `steps.metadata` (поле 1.1 — время, 9 — блок токенов:
    /// 2 — вход, 3 — выход, 5 — чтение из кэша, 11 — ID ответа). Модель — из `gen_metadata` (поле 1.21) по ID ответа.
    /// В `gen_metadata` лежит и весь промпт (поле 1.2), строки бывают по 50+ МБ: такие не читаем вовсе
    /// (`length()` не загружает blob), а модель для них берём самую частую в разговоре.
    private static func scanAntigravity(since: Date, _ add: Adder) {
        let base = SnapshotIO.realHome.appendingPathComponent(".gemini")
        for dir in ["antigravity-cli/conversations", "antigravity/conversations"] {
            for file in databases(in: base.appendingPathComponent(dir), since: since) {
                autoreleasepool {
                    guard let db = SQLiteReader(file.url) else { return }
                    var names: [String: String] = [:]
                    var counts: [String: Int] = [:]
                    db.each("SELECT data FROM gen_metadata WHERE length(data) < 1000000") { blob in
                        guard let g = Proto(blob).message(1), let rid = g.message(4)?.string(11) else { return }
                        let name = antigravityModel(g.string(21) ?? g.string(19) ?? "Antigravity")
                        names[rid] = name
                        counts[name, default: 0] += 1
                    }
                    let fallback = counts.max { $0.value < $1.value }?.key ?? "Antigravity"
                    let session = file.url.deletingPathExtension().lastPathComponent
                    db.each("SELECT metadata FROM steps WHERE metadata IS NOT NULL") { blob in
                        let m = Proto(blob)
                        guard let u = m.message(9), let ts = m.message(1)?.int(1) else { return }
                        let tokens = Int(u.int(2) ?? 0) + Int(u.int(3) ?? 0)
                        add(u.string(11).flatMap { names[$0] } ?? fallback, .antigravity,
                            Date(timeIntervalSince1970: TimeInterval(ts)), tokens, session)
                    }
                }
            }
        }
    }

    /// «Gemini 3.8 Flash (Low)», «gemini-3.8-flash-n», «Gemini 3.8 Flash Tiered» → «Gemini 3.8 Flash»:
    /// варианты одной модели (уровень рассуждений, тариф) сводятся в одну строку.
    private static func antigravityModel(_ raw: String) -> String {
        var words = Fmt.modelName(raw.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression))
            .split(separator: " ").map(String.init)
        while words.count > 1, ["n", "tiered", "thinking"].contains(words.last!.lowercased()) { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static func databases(in dir: URL, since: Date) -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        func mtime(_ path: String) -> Date? { (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".db") }.compactMap { name in
            let url = dir.appendingPathComponent(name)
            // Свежие записи могут лежать в -wal, а у самой базы mtime старый.
            guard let m = [mtime(url.path), mtime(url.path + "-wal")].compactMap({ $0 }).max(), m >= since else { return nil }
            return (url, m)
        }
    }

    // MARK: Файлы

    private static func files(under root: URL, since: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            if let d = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate, d >= since {
                out.append(url)
            }
        }
        return out
    }

    /// Разбирает только строки, где есть одна из подстрок: логи большие, а нужное — малая часть.
    /// Каждая строка — в своём autoreleasepool: JSONSerialization отдаёт autoreleased-объекты, а у потоков
    /// Swift concurrency нет пула, который бы их чистил, — без этого скан оставлял сотни мегабайт в куче.
    private static func lines(_ url: URL, containing needles: [String], _ body: ([String: Any]) -> Void) {
        // Проход по байтам отображённого файла: split/range(of:) на срезах Data делали временные копии,
        // и malloc оставлял себе сотни мегабайт освобождённых больших блоков.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
        let ns = needles.map { Array($0.utf8) }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let n = raw.count
            var start = 0
            while start < n {
                let end = memchr(base + start, 0x0A, n - start).map { UnsafeRawPointer($0) - base } ?? n
                let len = end - start
                if len > 0, ns.contains(where: { memmem(base + start, len, $0, $0.count) != nil }) {
                    autoreleasepool {
                        if let obj = J.object(Data(bytes: base + start, count: len)) as? [String: Any] { body(obj) }
                    }
                }
                start = end + 1
            }
        }
    }
}

/// Чтение SQLite-базы только для чтения. Обычная SQLite WAL-координация может
/// использовать соседние `-wal`/`-shm` файлы, чтобы безопасно видеть активные записи.
private final class SQLiteReader {
    private var db: OpaquePointer?

    init?(_ url: URL) {
        // Pass the filesystem path directly: URI parsing would reinterpret literal
        // characters such as ?, # and % in conversation filenames.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        // Bound waits when another process holds a conflicting SQLite lock.
        sqlite3_busy_timeout(db, 250)
    }

    deinit { sqlite3_close(db) }

    func each(_ sql: String, _ body: (Data) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            guard let p = sqlite3_column_blob(st, 0) else { continue }
            body(Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0))))
        }
    }
}

/// Минимальный разбор protobuf без схемы: первые поля с нужным номером.
private struct Proto {
    private var fields: [(number: Int, varint: UInt64?, bytes: Data?)] = []

    init(_ data: Data) {
        let d = Data(data)
        var i = 0
        func varint() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < d.count, shift < 64 {
                let c = d[i]
                i += 1
                r |= UInt64(c & 0x7f) << shift
                if c < 0x80 { return r }
                shift += 7
            }
            return nil
        }
        while i < d.count {
            guard let key = varint() else { return }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint() else { return }
                fields.append((number, v, nil))
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let len = varint(), len <= UInt64(d.count - i) else { return }
                fields.append((number, nil, d.subdata(in: i..<i + Int(len))))
                i += Int(len)
            default: return
            }
        }
    }

    func int(_ n: Int) -> UInt64? { fields.first { $0.number == n && $0.varint != nil }?.varint }
    func message(_ n: Int) -> Proto? { fields.first { $0.number == n && $0.bytes != nil }?.bytes.map(Proto.init) }
    func string(_ n: Int) -> String? {
        fields.first { $0.number == n && $0.bytes != nil }?.bytes.flatMap { String(data: $0, encoding: .utf8) }
    }
}
