import AppKit
import Carbon.HIToolbox
import UserNotifications

// MARK: - Настройки

enum Pref {
    static let requireVPN = "requireVPN"
    static let compact = "menu.compact"
    static let notify = "notify.enabled"
    static let threshold = "notify.threshold"
    static let notifyReset = "notify.reset"
    static let fastPoll = "poll.fast"
    static let defaultAgent = "agent.default"
    static let terminal = "agent.terminal"
    static let hotkey = "hotkey.enabled"

    static func menuKey(_ p: Provider) -> String { "menu.\(p.rawValue)" }

    static func register() {
        var defaults: [String: Any] = [
            requireVPN: true, compact: false, notify: true, threshold: 95.0, notifyReset: true,
            fastPoll: true, defaultAgent: Provider.claude.rawValue, terminal: Terminals.apple, hotkey: true,
        ]
        for p in Provider.allCases { defaults[menuKey(p)] = true }
        UserDefaults.standard.register(defaults: defaults)
    }

    static var visibleProviders: [Provider] {
        Provider.allCases.filter { UserDefaults.standard.bool(forKey: menuKey($0)) }
    }

    static var defaultProvider: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: defaultAgent) ?? "") ?? .claude
    }
}

// MARK: - Запуск агента в терминале

enum Terminals {
    static let apple = "com.apple.Terminal"
    static let ghostty = "com.mitchellh.ghostty"
    private static let known: [(id: String, name: String)] = [
        (apple, "Терминал"), ("com.googlecode.iterm2", "iTerm"), (ghostty, "Ghostty"),
    ]

    static var installed: [(id: String, name: String)] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
            .map { ($0.id, L($0.name)) }
    }
}

enum Launcher {
    /// Открывает CLI агента в выбранном терминале. Возвращает текст ошибки или nil.
    static func launch(_ p: Provider) -> String? {
        guard let path = CLI.find(p.command) else { return L("\(p.command) CLI не найден") }
        let dir = SnapshotIO.directory.appendingPathComponent("launch", isDirectory: true)
        let script = dir.appendingPathComponent("\(p.command).command")
        let body = "#!/bin/zsh -l\ncd \"$HOME\"\nclear\nexec '\(path.replacingOccurrences(of: "'", with: "'\\''"))'\n"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return error.localizedDescription
        }

        let id = UserDefaults.standard.string(forKey: Pref.terminal) ?? Terminals.apple
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Terminals.apple)
        else { return L("Терминал не найден") }
        if id == Terminals.ghostty {
            // Ghostty не открывает .command, но умеет запускать команду через -e.
            _ = Shell.run("/usr/bin/open", ["-na", app.path, "--args", "-e", script.path], timeout: 10)
        } else {
            NSWorkspace.shared.open([script], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
        return nil
    }
}

// MARK: - Уведомления

enum NotificationDecisions {
    static func isReset(previous: LimitWindow, current: LimitWindow,
                        previousObservedAt: Date, observedAt: Date,
                        threshold: Double) -> Bool {
        guard previous.name == current.name,
              let oldDeadline = previous.resetsAt,
              let newDeadline = current.resetsAt,
              oldDeadline.timeIntervalSince1970.isFinite,
              newDeadline.timeIntervalSince1970.isFinite,
              oldDeadline <= observedAt,
              newDeadline > observedAt,
              newDeadline > oldDeadline,
              previous.effectiveUsed(at: previousObservedAt) >= threshold,
              current.effectiveUsed(at: observedAt) < threshold else { return false }
        return true
    }

    static func retainNewestKeys(_ keys: Set<String>, limit: Int = 150) -> Set<String> {
        guard limit >= 0 else { return keys }
        guard keys.count > limit else { return keys }
        return Set(keys.sorted { lhs, rhs in
            let leftTimestamp = trailingTimestamp(lhs)
            let rightTimestamp = trailingTimestamp(rhs)
            if leftTimestamp != rightTimestamp { return leftTimestamp < rightTimestamp }
            return lhs < rhs
        }.suffix(limit))
    }

    private static func trailingTimestamp(_ key: String) -> Int64 {
        guard let tail = key.split(separator: "|").last,
              let timestamp = Int64(tail) else { return Int64.min }
        return timestamp
    }
}

@MainActor
final class Notifier {
    static let shared = Notifier(defaults: .standard)
    private let sentKey = "notify.sent"
    private let defaults: UserDefaults
    private let sink: @MainActor (String, String) -> Void
    private var sent: Set<String>

    init(defaults: UserDefaults, sink: @escaping @MainActor (String, String) -> Void = Notifier.deliver) {
        self.defaults = defaults
        self.sink = sink
        sent = Set(defaults.stringArray(forKey: sentKey) ?? [])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        sink(title, body)
    }

    private static func deliver(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Предупреждение при достижении порога (один раз на период окна) и сообщение о сбросе.
    func check(prev: Snapshot, next: Snapshot) {
        let threshold = defaults.double(forKey: Pref.threshold)
        let now = Date()
        let observedAt = next.generatedAt
        for s in next.providers {
            let old = prev.status(s.provider)
            for w in s.windows {
                let used = w.effectiveUsed(at: now)
                let key = "\(s.provider.rawValue)|\(w.name)|\(Int(w.resetsAt?.timeIntervalSince1970 ?? 0))"
                if defaults.bool(forKey: Pref.notify), used >= threshold, sent.insert(key).inserted {
                    let reset = Fmt.resetIn(w.resetsAt, now: now) ?? ""
                    post(title: "\(s.provider.title) — \(Fmt.percent(used)) · \(Fmt.window(w.name))",
                         body: reset.prefix(1).uppercased() + reset.dropFirst())
                }
                guard defaults.bool(forKey: Pref.notifyReset),
                      let ow = old.windows.first(where: { $0.name == w.name }),
                      NotificationDecisions.isReset(previous: ow, current: w,
                                                    previousObservedAt: prev.generatedAt,
                                                    observedAt: observedAt, threshold: threshold) else { continue }
                let resetKey = "reset|\(s.provider.rawValue)|\(ow.name)|\(Int(ow.resetsAt?.timeIntervalSince1970 ?? 0))"
                if sent.insert(resetKey).inserted {
                    post(title: LF("%@ — лимит сброшен", s.provider.title),
                         body: LF("Лимит обновлён; использовано %@", Fmt.percent(w.effectiveUsed(at: observedAt))))
                }
            }
        }
        if sent.count > 300 { sent = NotificationDecisions.retainNewestKeys(sent) }
        defaults.set(Array(sent), forKey: sentKey)
    }
}

// MARK: - Глобальное сочетание ⌃⌥⌘A

final class HotKey {
    static var handler: (() -> Void)?
    private var ref: EventHotKeyRef?
    private static var installed = false

    var isRegistered: Bool { ref != nil }

    func register() {
        guard ref == nil else { return }
        if !Self.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
            Self.installed = true
        }
        let id = EventHotKeyID(signature: OSType(0x41494C4D), id: 1) // 'AILM'
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
