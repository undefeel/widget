import AppKit
import Foundation
import WidgetKit

@MainActor
final class LimitsStore: ObservableObject {
    static let requireVPNKey = Pref.requireVPN

    @Published private(set) var snapshot: Snapshot
    @Published private(set) var isRefreshing = false
    @Published private(set) var now = Date()

    private var lastAttempt: [Provider: Date] = [:]
    private var lastUsageScan: Date?
    private var timer: Timer?

    /// Как часто запускать каждый CLI (секунды).
    private let intervals: [Provider: TimeInterval] = [.claude: 300, .codex: 120, .antigravity: 300]
    /// Как часто проверять VPN и сроки опроса.
    private let tickInterval: TimeInterval = 15
    /// Статистика токенов по логам.
    private let usageInterval: TimeInterval = 900
    /// Ускоренный опрос, когда до порога меньше 15 пунктов.
    private let fastInterval: TimeInterval = 90

    /// Ключ локализации (переводится при отображении).
    static let vpnOffMessage = "VPN выключен — лимиты не запрашиваются"

    private var requireVPN: Bool { UserDefaults.standard.bool(forKey: Self.requireVPNKey) }

    init() {
        Pref.register()
        snapshot = SnapshotIO.load() ?? .empty
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; now = Date() }

        let prev = snapshot

        // 1. Проверка VPN: без него ничего не запрашиваем и не читаем.
        if requireVPN {
            let vpnOn = await Task.detached { VPN.isActive() }.value
            if !vpnOn {
                var s = prev
                s.paused = Self.vpnOffMessage
                publish(s, prev: prev)
                return
            }
        }
        // VPN только что включился — опрашиваем всё сразу.
        let resumed = prev.paused != nil
        let start = Date()
        func due(_ p: Provider) -> Bool {
            force || resumed || lastAttempt[p].map { start.timeIntervalSince($0) >= interval(p, prev: prev) } ?? true
        }
        let doUsage = force || resumed || lastUsageScan.map { start.timeIntervalSince($0) >= usageInterval } ?? true
        if doUsage { lastUsageScan = start }
        let doClaude = due(.claude), doCodex = due(.codex), doAG = due(.antigravity)
        for (p, d) in [(Provider.claude, doClaude), (.codex, doCodex), (.antigravity, doAG)] where d {
            lastAttempt[p] = start
        }

        // 2. Запуск CLI параллельно.
        async let c = Task.detached { doClaude ? ClaudeFetcher.fetchCLI() : nil }.value
        async let x = Task.detached { doCodex ? CodexFetcher.fetchCLI() : nil }.value
        async let a = Task.detached { doAG ? AntigravityFetcher.fetchCLI() : nil }.value
        async let local = Task.detached { (ClaudeFetcher.fromStatusline(), CodexFetcher.fromSessionLogs()) }.value
        async let u = Task.detached { doUsage ? UsageScanner.scan() : nil }.value
        let (cRes, xRes, aRes, (claudeSL, codexLogs), usage) = await (c, x, a, local, u)

        let next = Snapshot(providers: [
            merge(fresh: cRes, fallback: claudeSL, prev: prev.status(.claude)),
            merge(fresh: xRes, fallback: codexLogs, prev: prev.status(.codex)),
            merge(fresh: aRes, fallback: nil, prev: prev.status(.antigravity)),
        ], generatedAt: Date(), paused: nil, usage: usage ?? prev.usage)
        publish(next, prev: prev)
    }

    private func interval(_ p: Provider, prev: Snapshot) -> TimeInterval {
        let base = intervals[p]!
        let d = UserDefaults.standard
        guard d.bool(forKey: Pref.fastPoll), let h = prev.status(p).headline(),
              h >= d.double(forKey: Pref.threshold) - 15 else { return base }
        return min(base, fastInterval)
    }

    private func publish(_ next: Snapshot, prev: Snapshot) {
        snapshot = next
        SnapshotIO.save(next)
        Notifier.shared.check(prev: prev, next: next)
        if next.providers != prev.providers || next.paused != prev.paused || next.usage != prev.usage {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Свежий результат CLI; если его нет — самые новые из резервных/прошлых данных.
    private func merge(fresh: Result<ProviderStatus, FetchError>?, fallback: ProviderStatus?,
                       prev: ProviderStatus) -> ProviderStatus {
        if case .success(var s)? = fresh {
            if s.detail == nil { s.detail = prev.detail }
            return s
        }
        let candidates = [fallback, prev.windows.isEmpty ? nil : prev].compactMap { $0 }
        var out = candidates.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) } ?? prev
        if out.detail == nil { out.detail = prev.detail }
        switch fresh {
        case .failure(let e)?: out.error = e.message
        case .success?: break
        case nil: if out.updatedAt != prev.updatedAt { out.error = nil }
        }
        return out
    }
}
