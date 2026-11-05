import AppKit
import Foundation
import SwiftUI

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex, antigravity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "staroflife.fill"
        case .codex: return "terminal.fill"
        case .antigravity: return "atom"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.23, green: 0.56, blue: 0.92)
        case .antigravity: return Color(red: 0.56, green: 0.42, blue: 0.94)
        }
    }

    /// Команда CLI агента.
    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .antigravity: return "agy"
        }
    }

    var agentTitle: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }
}

struct LimitWindow: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    /// 0...100
    var usedPercent: Double
    var resetsAt: Date?

    /// Если время сброса уже прошло — окно обнулилось.
    func effectiveUsed(at now: Date = Date()) -> Double {
        if let r = resetsAt, r <= now { return 0 }
        return min(max(usedPercent, 0), 100)
    }
}

struct ProviderStatus: Codable, Identifiable, Equatable {
    var provider: Provider
    var windows: [LimitWindow] = []
    var updatedAt: Date?
    var source: String?
    var detail: String?
    var error: String?

    var id: Provider { provider }

    /// Самый «узкий» лимит — максимальный процент использования.
    func headline(at now: Date = Date()) -> Double? {
        windows.map { $0.effectiveUsed(at: now) }.max()
    }
}

/// Токены одной модели по дням за последние 5 календарных недель.
struct ModelUsage: Codable, Hashable, Identifiable {
    var id: String { model }
    var model: String
    var provider: Provider
    /// По дням, от самого старого к сегодняшнему.
    var days: [Int]
    /// Сессии за последние 7 дней.
    var sessions: Int
    /// Сессии за весь период.
    var sessionsMonth: Int? = nil

    /// Токены за последние 7 дней.
    var weekTotal: Int { days.suffix(7).reduce(0, +) }
}

struct UsageStats: Codable, Equatable {
    /// Начала суток, от самого старого к сегодняшнему.
    var dayStarts: [Date]
    /// Отсортированы по убыванию токенов за весь период.
    var models: [ModelUsage]
    var sessionsToday: Int
    var generatedAt: Date

    /// За последние 7 дней.
    var total: Int { models.reduce(0) { $0 + $1.weekTotal } }
    var top: ModelUsage? { models.filter { $0.weekTotal > 0 }.max { $0.weekTotal < $1.weekTotal } }
}

struct Snapshot: Codable, Equatable {
    var providers: [ProviderStatus]
    var generatedAt: Date
    /// Причина паузы опроса (например, выключен VPN). nil — опрос идёт.
    var paused: String? = nil
    var usage: UsageStats? = nil

    static var empty: Snapshot {
        Snapshot(providers: Provider.allCases.map { ProviderStatus(provider: $0) }, generatedAt: Date())
    }

    func status(_ p: Provider) -> ProviderStatus {
        providers.first { $0.provider == p } ?? ProviderStatus(provider: p)
    }
}

enum SnapshotIO {
    /// Реальный домашний каталог (в песочнице виджета NSHomeDirectory указывает на контейнер).
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static var directory: URL {
        realHome.appendingPathComponent("Library/Application Support/AILimits", isDirectory: true)
    }

    static var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Snapshot.self, from: data)
    }

    static func save(_ s: Snapshot) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: snapshotURL, options: .atomic)
    }
}

// MARK: - Локализация

/// Строка из Localizable.strings текущего бандла (ключ — русский текст).
func L(_ key: String) -> String { NSLocalizedString(key, bundle: .main, comment: "") }
func LF(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }

enum Fmt {
    static func percent(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int(v.rounded()))%"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? LF("%d дн %d ч", d, h) : LF("%d дн", d) }
        if h > 0 { return m > 0 ? LF("%d ч %d мин", h, m) : LF("%d ч", h) }
        return LF("%d мин", max(m, 1))
    }

    static func resetIn(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        if date <= now { return L("сброшен") }
        return LF("сброс через %@", duration(date.timeIntervalSince(now)))
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return L("нет данных") }
        let s = now.timeIntervalSince(date)
        if s < 60 { return L("только что") }
        return LF("%@ назад", duration(s))
    }

    static func levelColor(_ used: Double) -> Color {
        if used >= 90 { return .red }
        if used >= 70 { return .orange }
        return .green
    }

    static func barColor(_ used: Double, _ tint: Color) -> Color {
        used >= 90 ? .red : (used >= 70 ? .orange : tint)
    }

    /// Цвет текста процента: обычный, пока до лимита далеко.
    static func levelText(_ used: Double) -> Color {
        // Системные оранжевый и красный на светлом фоне не дотягивают до 4.5:1 — в светлой теме темнее.
        if used >= 90 { return .dynamic(light: "d70015", dark: "ff6961") }
        if used >= 70 { return .dynamic(light: "b25000", dark: "ffb340") }
        return .primary
    }

    static func tokens(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        if n >= 1_000_000 {
            f.maximumFractionDigits = 2
            return LF("%@ млн", f.string(from: NSNumber(value: Double(n) / 1_000_000)) ?? "")
        }
        if n >= 1000 {
            f.maximumFractionDigits = n >= 100_000 ? 0 : 1
            return LF("%@ тыс", f.string(from: NSNumber(value: Double(n) / 1000)) ?? "")
        }
        return "\(n)"
    }

    /// `claude-opus-5-5` → `Claude Opus 5.5`, `claude-sonnet-4-5-20250929` → `Claude Sonnet 4.5`, `gpt-6.1-sol` → `GPT-6.1 Sol`.
    static func modelName(_ raw: String) -> String {
        var parts = raw.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        var words: [String] = [], nums: [String] = []
        func flush() { if !nums.isEmpty { words.append(nums.joined(separator: ".")); nums = [] } }
        for p in parts {
            if Int(p) != nil { nums.append(p); continue }
            flush()
            words.append(p.lowercased() == "gpt" ? "GPT" : p.prefix(1).uppercased() + p.dropFirst())
        }
        flush()
        if words.first == "GPT", words.count > 1 { words[0] = "GPT-" + words.remove(at: 1) }
        return words.joined(separator: " ")
    }

    /// Короткое имя окна для тесных мест: «5 ч», «нед», «Gemini».
    static func windowShort(_ name: String) -> String {
        if name == "5 часов" { return L("5 ч") }
        if name == "Неделя" { return L("нед") }
        return L(name.components(separatedBy: " · ").first ?? name)
    }

    private static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return f
    }

    static func day(_ date: Date, long: Bool = false) -> String {
        if !long, Calendar.current.isDateInToday(date) { return L("Сегодня") }
        let f = dayFormatter
        f.setLocalizedDateFormatFromTemplate(long ? "EEdMMM" : "EE")
        return f.string(from: date)
    }

    /// «27 окт».
    static func dayMonth(_ date: Date) -> String {
        let f = dayFormatter
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date)
    }

    static func windowName(minutes: Int) -> String {
        switch minutes {
        case 300: return "5 часов"
        case 1440: return "Сутки"
        case 10080: return "Неделя"
        default:
            if minutes % 1440 == 0 { return LF("%d дн", minutes / 1440) }
            if minutes % 60 == 0 { return LF("%d ч", minutes / 60) }
            return LF("%d мин", minutes)
        }
    }

    static func plan(_ raw: String) -> String {
        LF("План %@", raw.replacingOccurrences(of: "План ", with: ""))
    }

    /// Названия окон хранятся в snapshot как ключи («Gemini · Неделя») и переводятся при отображении.
    static func window(_ name: String) -> String {
        let parts = name.components(separatedBy: " · ")
        // «5 часов» само по себе переводится как «Сессия · 5 ч»; внутри составного имени нужно короткое «5 ч».
        guard parts.count > 1 else { return L(name) }
        return parts.map { $0 == "5 часов" ? L("5 ч") : L($0) }.joined(separator: " · ")
    }
}

/// Полоска лимита: `ProgressView` (для VoiceOver) со своим стилем — системный `.linear` в macOS
/// после смены темы перекрашивается в акцентный цвет и теряет цвет провайдера.
struct LimitBar: View {
    var used: Double
    var tint: Color

    var body: some View {
        ProgressView(value: min(max(used, 0), 100), total: 100)
            .progressViewStyle(LimitBarStyle(tint: Fmt.barColor(used, tint)))
    }
}

struct LimitBarStyle: ProgressViewStyle {
    var tint: Color
    var height: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        let f = configuration.fractionCompleted ?? 0
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint).frame(width: f > 0 ? max(g.size.height, g.size.width * f) : 0)
            }
        }
        .frame(height: height)
    }
}

/// Кольцо с процентом в центре (средний виджет) — системный `Gauge` (accessoryCircularCapacity).
struct LimitRing: View {
    var used: Double?
    var tint: Color
    var size: CGFloat = 64

    var body: some View {
        let v = used ?? 0
        Gauge(value: min(max(v, 0), 100), in: 0...100) {
            EmptyView()
        } currentValueLabel: {
            Text(Fmt.percent(used)).monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(Fmt.barColor(v, tint))
        .scaleEffect(size / 52)
        .frame(width: size, height: size)
    }
}

// MARK: - Палитра серий (модели в статистике токенов)

enum Palette {
    /// Порядок фиксирован: цвет закреплён за моделью, а не за её местом после фильтра.
    private static let pairs: [(String, String)] = [
        ("2a78d6", "3987e5"), ("eb6834", "d95926"), ("1baf7a", "199e70"),
        ("eda100", "c98500"), ("e87ba4", "d55181"), ("008300", "008300"),
    ]
    static let count = pairs.count
    static let other = Color.dynamic(light: "8e8e93", dark: "8e8e93")

    static func color(_ index: Int) -> Color {
        index < pairs.count ? .dynamic(light: pairs[index].0, dark: pairs[index].1) : other
    }
}

extension Color {
    static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            NSColor(hex: ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

// MARK: - Иконки (извлекаются из установленных приложений при сборке)

enum IconStore {
    private static var cache: [String: NSImage] = [:]

    static func image(_ p: Provider, glyph: Bool) -> NSImage? {
        let name = glyph ? "\(p.rawValue)-glyph" : p.rawValue
        if let img = cache[name] { return img }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        if glyph { img.isTemplate = true }
        cache[name] = img
        return img
    }
}

/// Цветная иконка приложения.
struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = 16

    var body: some View {
        if let img = IconStore.image(provider, glyph: false) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: provider.symbol)
                .font(.system(size: size * 0.75, weight: .bold))
                .foregroundStyle(provider.tint)
                .frame(width: size, height: size)
        }
    }
}

/// Монохромный силуэт логотипа (для строки меню).
struct ProviderGlyph: View {
    let provider: Provider
    var size: CGFloat = 13

    var body: some View {
        if let img = IconStore.image(provider, glyph: true) {
            Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.symbol).font(.system(size: size * 0.8, weight: .bold))
        }
    }
}
