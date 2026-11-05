import Foundation

struct FetchError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Запуск процессов

enum Shell {
    /// Запускает процесс с таймаутом. `stopWhen` позволяет завершить его досрочно,
    /// как только в stdout появилось нужное (для долгоживущих серверов вроде `codex app-server`).
    static func run(_ path: String, _ args: [String], input: String? = nil, keepStdinOpen: Bool = false,
                    cwd: URL? = nil, env: [String: String]? = nil, timeout: TimeInterval = 30,
                    stopWhen: ((String) -> Bool)? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = input == nil ? FileHandle.nullDevice : inp

        let lock = NSLock()
        var buffer = Data()
        let done = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; done.signal(); return }
            lock.lock(); buffer.append(d); let s = String(decoding: buffer, as: UTF8.self); lock.unlock()
            if let stopWhen, stopWhen(s) { done.signal() }
        }

        do { try p.run() } catch { return "" }
        if let input {
            inp.fileHandleForWriting.write(Data(input.utf8))
            if !keepStdinOpen { try? inp.fileHandleForWriting.close() }
        }
        _ = done.wait(timeout: .now() + timeout)
        if p.isRunning { p.terminate() }
        out.fileHandleForReading.readabilityHandler = nil
        try? inp.fileHandleForWriting.close()
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Поиск CLI: у GUI-приложения нет PATH из shell.
enum CLI {
    private static let home = SnapshotIO.realHome.path
    static let searchDirs = [
        "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
        "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "\(home)/bin",
    ]
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static var environment: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = (searchDirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        e["HOME"] = home
        e["NO_COLOR"] = "1"
        e["TERM"] = "dumb"
        return e
    }

    static func find(_ name: String) -> String? {
        lock.lock(); if let c = cache[name] { lock.unlock(); return c }; lock.unlock()
        var found = searchDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            let r = Shell.run("/bin/zsh", ["-lc", "command -v \(name)"], timeout: 10)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if r.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: r) { found = r }
        }
        if let found { lock.lock(); cache[name] = found; lock.unlock() }
        return found
    }

    /// Рабочий каталог для CLI, чтобы не засорять чужие проекты.
    static var workDir: URL {
        try? FileManager.default.createDirectory(at: SnapshotIO.directory, withIntermediateDirectories: true)
        return SnapshotIO.directory
    }
}

// MARK: - VPN

enum VPN {
    /// VPN считается включённым, если какой-то VPN-сервис macOS в состоянии Connected
    /// или маршрут по умолчанию идёт через туннельный интерфейс.
    static func isActive() -> Bool {
        let nc = Shell.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 5)
        if nc.split(separator: "\n").contains(where: { $0.contains("(Connected)") }) { return true }
        let route = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 5)
        if let line = route.split(separator: "\n").first(where: { $0.contains("interface:") }),
           let iface = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) {
            return ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { iface.hasPrefix($0) }
        }
        return false
    }
}

// MARK: - JSON

enum J {
    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func date(_ v: Any?) -> Date? {
        func epoch(_ n: Double) -> Date? { n <= 0 ? nil : Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        if let n = v as? NSNumber { return epoch(n.doubleValue) }
        guard let s = v as? String else { return nil }
        if let n = Double(s) { return epoch(n) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func object(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }
}

// MARK: - Claude: `claude -p /usage`

enum ClaudeFetcher {
    static var statuslineCacheURL: URL {
        SnapshotIO.directory.appendingPathComponent("claude-statusline.json")
    }

    static func fetchCLI() -> Result<ProviderStatus, FetchError> {
        guard let claude = CLI.find("claude") else { return .failure(FetchError(L("claude CLI не найден"))) }
        let out = Shell.run(claude, ["-p", "/usage", "--no-session-persistence"],
                            cwd: CLI.workDir, env: CLI.environment, timeout: 60)
        let windows = parseUsage(out)
        guard !windows.isEmpty else {
            let first = out.split(separator: "\n").first.map(String.init) ?? L("пустой ответ")
            return .failure(FetchError("claude /usage: \(first.prefix(80))"))
        }
        return .success(ProviderStatus(provider: .claude, windows: windows, updatedAt: Date(), source: "claude /usage"))
    }

    /// Строки вида: `Current week (all models): 12% used · resets Nov 6 at 8:59am (Europe/Moscow)`
    static func parseUsage(_ text: String) -> [LimitWindow] {
        let re = try! NSRegularExpression(
            pattern: #"^\s*(.+?):\s*(\d+(?:\.\d+)?)%\s*used(?:\s*·\s*resets\s+(.+?))?\s*(?:\(([^()]+)\))?\s*$"#)
        var result: [LimitWindow] = []
        for line in text.split(separator: "\n").map(String.init) {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func g(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            guard let label = g(1), let used = g(2).flatMap(Double.init) else { continue }
            let tz = g(4).flatMap { TimeZone(identifier: $0) } ?? .current
            result.append(LimitWindow(name: windowName(label), usedPercent: used,
                                      resetsAt: g(3).flatMap { parseReset($0, tz: tz) }))
        }
        return result
    }

    private static func windowName(_ label: String) -> String {
        let l = label.lowercased()
        if l.contains("session") { return "5 часов" }
        if l.contains("week") {
            if l.contains("all models") || !l.contains("(") { return "Неделя" }
            if l.contains("opus") { return "Неделя · Opus" }
            if l.contains("sonnet") { return "Неделя · Sonnet" }
            if let a = label.firstIndex(of: "("), let b = label.firstIndex(of: ")"), a < b {
                return "Неделя · " + label[label.index(after: a)..<b]
            }
            return "Неделя"
        }
        return label
    }

    /// `Nov 1 at 1:59am`, `1:59am`, `Nov 6 at 9am`, `Nov 6`
    static func parseReset(_ s: String, tz: TimeZone, now: Date = Date()) -> Date? {
        let text = s.trimmingCharacters(in: .whitespaces).lowercased()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        for fmt in ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d, h:mma", "MMM d, ha", "MMM d"] {
            f.dateFormat = fmt
            guard let d = f.date(from: text) else { continue }
            var c = cal.dateComponents([.month, .day, .hour, .minute], from: d)
            c.year = cal.component(.year, from: now)
            guard var date = cal.date(from: c) else { continue }
            if date < now.addingTimeInterval(-86400) { date = cal.date(byAdding: .year, value: 1, to: date) ?? date }
            return date
        }
        for fmt in ["h:mma", "ha"] {
            f.dateFormat = fmt
            guard let d = f.date(from: text) else { continue }
            let t = cal.dateComponents([.hour, .minute], from: d)
            guard var date = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: now) else { continue }
            if date < now { date = cal.date(byAdding: .day, value: 1, to: date) ?? date }
            return date
        }
        return nil
    }

    /// Кэш, который пишет statusline Claude Code (поле rate_limits).
    static func fromStatusline() -> ProviderStatus? {
        guard let data = try? Data(contentsOf: statuslineCacheURL),
              let json = J.object(data) as? [String: Any],
              let rl = json["rate_limits"] as? [String: Any] else { return nil }
        let names = ["five_hour": "5 часов", "seven_day": "Неделя",
                     "seven_day_opus": "Неделя · Opus", "seven_day_sonnet": "Неделя · Sonnet"]
        var windows: [LimitWindow] = []
        for key in ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"] {
            guard let w = rl[key] as? [String: Any], let used = J.num(w["used_percentage"]) else { continue }
            windows.append(LimitWindow(name: names[key]!, usedPercent: used, resetsAt: J.date(w["resets_at"])))
        }
        guard !windows.isEmpty else { return nil }
        return ProviderStatus(provider: .claude, windows: windows, updatedAt: J.date(json["ts"]),
                              source: "statusline Claude Code")
    }
}

// MARK: - Codex: `codex app-server` → account/rateLimits/read

enum CodexFetcher {
    static func fetchCLI() -> Result<ProviderStatus, FetchError> {
        guard let codex = CLI.find("codex") else { return .failure(FetchError(L("codex CLI не найден"))) }
        let input = [
            #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"ailimits","title":"AILimits","version":"1.0"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"method":"account/rateLimits/read","id":1}"#,
        ].joined(separator: "\n") + "\n"
        let out = Shell.run(codex, ["app-server"], input: input, keepStdinOpen: true, cwd: CLI.workDir,
                            env: CLI.environment, timeout: 30) { buf in
            // Есть полностью дочитанная строка с ответом на запрос id=1.
            buf.split(separator: "\n", omittingEmptySubsequences: false).dropLast().contains { $0.contains(#""id":1,"#) }
        }

        guard let line = out.split(separator: "\n").first(where: { $0.contains(#""id":1,"#) }),
              let msg = J.object(Data(line.utf8)) as? [String: Any]
        else { return .failure(FetchError(L("codex app-server не ответил"))) }
        if let err = msg["error"] as? [String: Any] {
            return .failure(FetchError("codex: \(err["message"] as? String ?? L("ошибка"))"))
        }
        guard let result = msg["result"] as? [String: Any],
              let rl = result["rateLimits"] as? [String: Any]
        else { return .failure(FetchError("codex: " + L("в ответе нет лимитов"))) }

        var windows: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any], let used = J.num(w["usedPercent"]) else { continue }
            let mins = J.num(w["windowDurationMins"]).map { Int($0) }
            windows.append(LimitWindow(name: mins.map { Fmt.windowName(minutes: $0) } ?? (key == "primary" ? "5 часов" : "Неделя"),
                                       usedPercent: used, resetsAt: J.date(w["resetsAt"])))
        }
        guard !windows.isEmpty else { return .failure(FetchError("codex: " + L("в ответе нет лимитов"))) }
        let plan = (rl["planType"] as? String)?.capitalized
        return .success(ProviderStatus(provider: .codex, windows: windows, updatedAt: Date(),
                                       source: "codex app-server", detail: plan))
    }

    /// Резерв: последнее событие token_count с rate_limits из логов сессий Codex.
    static func fromSessionLogs() -> ProviderStatus? {
        let fm = FileManager.default
        let root = SnapshotIO.realHome.appendingPathComponent(".codex/sessions")
        func subdirs(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        var files: [URL] = []
        outer: for y in subdirs(root) { for m in subdirs(y) { for d in subdirs(m) {
            files += ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jsonl" }
            if files.count >= 30 { break outer }
        } } }
        files.sort { mtime($0) > mtime($1) }

        for file in files.prefix(8) {
            guard let fh = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            try? fh.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
            guard let data = try? fh.readToEnd() else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
            where line.contains("\"rate_limits\"") {
                guard let obj = J.object(Data(line.utf8)) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any] else { continue }
                let ts = J.date(obj["timestamp"]) ?? mtime(file)
                var windows: [LimitWindow] = []
                for key in ["primary", "secondary"] {
                    guard let w = rl[key] as? [String: Any], let used = J.num(w["used_percent"]) else { continue }
                    let mins = J.num(w["window_minutes"]).map { Int($0) }
                    windows.append(LimitWindow(name: mins.map { Fmt.windowName(minutes: $0) } ?? key,
                                               usedPercent: used, resetsAt: J.date(w["resets_at"])))
                }
                if !windows.isEmpty {
                    return ProviderStatus(provider: .codex, windows: windows, updatedAt: ts, source: "логи сессий Codex")
                }
            }
        }
        return nil
    }
}

// MARK: - Antigravity: `agy -p /quota`

enum AntigravityFetcher {
    static func fetchCLI() -> Result<ProviderStatus, FetchError> {
        guard let agy = CLI.find("agy") else { return .failure(FetchError(L("agy CLI не найден"))) }
        let out = Shell.run(agy, ["-p", "/quota", "--print-timeout", "50s"],
                            cwd: CLI.workDir, env: CLI.environment, timeout: 60)
        let windows = parseQuota(out)
        guard !windows.isEmpty else {
            let first = out.split(separator: "\n").first.map(String.init) ?? L("пустой ответ")
            return .failure(FetchError("agy /quota: \(first.prefix(80))"))
        }
        return .success(ProviderStatus(provider: .antigravity, windows: windows, updatedAt: Date(), source: "agy /quota"))
    }

    /// Строки TSV: `Gemini Models	Weekly Limit Remaining	36%	2026-11-04T14:11:32Z`
    static func parseQuota(_ text: String) -> [LimitWindow] {
        var result: [LimitWindow] = []
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3,
                  let remaining = Double(cols[2].replacingOccurrences(of: "%", with: "")) else { continue }
            let group = cols[0]
                .replacingOccurrences(of: " models", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: " and ", with: "/")
            // Показываем только квоты Gemini: Claude и GPT считаются в своих провайдерах.
            guard group.lowercased().contains("gemini") else { continue }
            let kind = cols[1].lowercased()
            let window = kind.contains("week") ? "Неделя" : (kind.contains("five hour") || kind.contains("5") ? "5 часов" : cols[1])
            result.append(LimitWindow(name: "\(group) · \(window)", usedPercent: 100 - remaining,
                                      resetsAt: cols.count > 3 ? J.date(cols[3]) : nil))
        }
        return result
    }
}
