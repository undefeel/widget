import AppKit
import Foundation
import WidgetKit

/// Synchronous I/O seams kept on the Store boundary so refresh behavior can be
/// exercised with synthetic providers and disposable publication callbacks.
struct RefreshOperations {
    var vpnAllowed: () -> Bool
    var fetch: (Provider) -> Result<ProviderStatus, FetchError>?
    var fallback: (Provider) -> ProviderStatus?
    var usage: () -> UsageStats?
    var save: (Snapshot) -> Void
    var notify: @MainActor (Snapshot, Snapshot) -> Void
    var reloadWidgets: () -> Void

    static var live: RefreshOperations {
        RefreshOperations(
            vpnAllowed: {
                !UserDefaults.standard.bool(forKey: Pref.requireVPN) || VPN.isActive()
            },
            fetch: { provider in
                switch provider {
                case .claude: return ClaudeFetcher.fetchCLI()
                case .codex: return CodexFetcher.fetchCLI()
                case .antigravity: return AntigravityFetcher.fetchCLI()
                }
            },
            fallback: { provider in
                switch provider {
                case .claude: return ClaudeFetcher.fromStatusline()
                case .codex: return CodexFetcher.fromSessionLogs()
                case .antigravity: return nil
                }
            },
            usage: { UsageScanner.scan() },
            save: { SnapshotIO.save($0) },
            notify: { Notifier.shared.check(prev: $0, next: $1) },
            reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() }
        )
    }
}

@MainActor
final class LimitsStore: ObservableObject {
    static let requireVPNKey = Pref.requireVPN

    @Published private(set) var snapshot: Snapshot
    @Published private(set) var isRefreshing = false
    @Published private(set) var now = Date()

    private var lastAttempt: [Provider: Date] = [:]
    private var lastUsageScan: Date?
    private var limitsInFlight = false
    private var usageInFlight = false
    /// Every observed VPN block fences all results started before that block.
    private var generation: UInt64 = 0
    private var timer: Timer?
    private let operations: RefreshOperations

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

    init() {
        Pref.register()
        operations = .live
        snapshot = SnapshotIO.load() ?? .empty
        startAutomaticRefresh()
    }

    /// Test initializer: caller controls scheduling and every external read/write.
    init(snapshot: Snapshot, operations: RefreshOperations, startAutomatically: Bool = false) {
        self.snapshot = snapshot
        self.operations = operations
        if startAutomatically { startAutomaticRefresh() }
    }

    private func startAutomaticRefresh() {
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

    /// `force` affects provider limits only. Statistics run at their own due time.
    func refresh(force: Bool = false) async {
        defer { now = Date() }

        guard await vpnPermitted() else {
            return
        }

        let resumed = snapshot.paused != nil
        if resumed {
            var unpaused = snapshot
            unpaused.paused = nil
            publish(unpaused)
        }

        let start = Date()
        let current = snapshot
        let dueProviders = Provider.allCases.filter { provider in
            force || resumed || lastAttempt[provider].map {
                start.timeIntervalSince($0) >= interval(provider, previous: current)
            } ?? true
        }

        // Manual refresh never forces a scan; it may schedule one if its own
        // interval is due. A currently running physical scan is never duplicated.
        let usageDue = lastUsageScan.map { start.timeIntervalSince($0) >= usageInterval } ?? true
        if usageDue { startUsageScan(generation: generation, startedAt: start) }

        guard !limitsInFlight, !dueProviders.isEmpty else { return }
        limitsInFlight = true
        isRefreshing = true
        let requestGeneration = generation
        for provider in dueProviders { lastAttempt[provider] = start }

        // Provider processes remain concurrent. Each result is gated and merged
        // as soon as it finishes, so a slow unrelated CLI cannot hold it back.
        await withTaskGroup(of: Provider.self) { group in
            for provider in dueProviders {
                group.addTask { [weak self] in
                    await self?.fetchAndPublish(provider, generation: requestGeneration)
                    return provider
                }
            }
            for await _ in group { }
        }
        limitsInFlight = false
        isRefreshing = false
        if requestGeneration != generation {
            for provider in dueProviders { lastAttempt[provider] = nil }
        }
    }

    private func fetchAndPublish(_ provider: Provider, generation requestGeneration: UInt64) async {
        let fetchOperation = operations.fetch
        let fresh = await Task.detached { fetchOperation(provider) }.value

        // Fallback reads can touch local histories. Recheck the gate after the
        // CLI and before starting that second physical operation.
        var fallback: ProviderStatus?
        if case .success? = fresh {
            fallback = nil
        } else if provider != .antigravity,
                  await completionPermitted(generation: requestGeneration) {
            let fallbackOperation = operations.fallback
            fallback = await Task.detached { fallbackOperation(provider) }.value
        }
        await finishProvider(provider, fresh: fresh, fallback: fallback,
                             generation: requestGeneration)
    }

    private func finishProvider(_ provider: Provider,
                                fresh: Result<ProviderStatus, FetchError>?,
                                fallback: ProviderStatus?, generation requestGeneration: UInt64) async {
        guard await completionPermitted(generation: requestGeneration) else { return }
        // Merge against the current snapshot after every await. A concurrent
        // usage result or VPN pause therefore remains intact.
        var next = snapshot
        next.providers = replacing(provider, with: merge(fresh: fresh, fallback: fallback,
                                                          previous: snapshot.status(provider)),
                                   in: next.providers)
        next.paused = nil
        publish(next)
    }

    private func completionPermitted(generation requestGeneration: UInt64) async -> Bool {
        guard await vpnPermitted() else {
            return false
        }
        return requestGeneration == generation
    }

    private func startUsageScan(generation scanGeneration: UInt64, startedAt: Date) {
        guard !usageInFlight else { return }
        usageInFlight = true
        lastUsageScan = startedAt
        let usageOperation = operations.usage
        Task.detached { [weak self] in
            let usage = usageOperation()
            await self?.finishUsage(usage, generation: scanGeneration)
        }
    }

    private func finishUsage(_ usage: UsageStats?, generation scanGeneration: UInt64) async {
        let allowedAtCompletion = await vpnPermitted()
        usageInFlight = false
        guard allowedAtCompletion, scanGeneration == generation else {
            if scanGeneration != generation { lastUsageScan = nil }
            return
        }
        guard let usage else { return }
        var next = snapshot
        next.usage = usage
        publish(next)
        now = Date()
    }

    private func vpnPermitted() async -> Bool {
        let checkGeneration = generation
        let check = operations.vpnAllowed
        let allowed = await Task.detached { check() }.value
        guard generation == checkGeneration else { return false }
        if !allowed { observeVPNBlock() }
        return allowed
    }

    private func observeVPNBlock() {
        generation &+= 1
        lastUsageScan = nil
        var paused = snapshot
        paused.paused = Self.vpnOffMessage
        publish(paused)
    }

    private func interval(_ provider: Provider, previous: Snapshot) -> TimeInterval {
        let base = intervals[provider]!
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Pref.fastPoll), let headline = previous.status(provider).headline(),
              headline >= defaults.double(forKey: Pref.threshold) - 15 else { return base }
        return min(base, fastInterval)
    }

    /// Persists only payload changes; generatedAt remains tied to actual data changes.
    private func publish(_ candidate: Snapshot) {
        let previous = snapshot
        guard candidate.providers != previous.providers || candidate.paused != previous.paused ||
                candidate.usage != previous.usage else { return }
        var next = candidate
        next.generatedAt = Date()
        snapshot = next
        operations.save(next)
        operations.notify(previous, next)
        operations.reloadWidgets()
    }

    private func replacing(_ provider: Provider, with status: ProviderStatus,
                           in providers: [ProviderStatus]) -> [ProviderStatus] {
        var result = providers
        if let index = result.firstIndex(where: { $0.provider == provider }) {
            result[index] = status
        } else {
            result.append(status)
        }
        return result
    }

    /// Fresh CLI data wins; failed/unavailable requests preserve the newest
    /// fallback or prior state and attach the original CLI error.
    private func merge(fresh: Result<ProviderStatus, FetchError>?, fallback: ProviderStatus?,
                       previous: ProviderStatus) -> ProviderStatus {
        if case .success(var status)? = fresh {
            if status.detail == nil { status.detail = previous.detail }
            return status
        }
        let candidates = [fallback, previous.windows.isEmpty ? nil : previous].compactMap { $0 }
        var result = candidates.max {
            ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast)
        } ?? previous
        if result.detail == nil { result.detail = previous.detail }
        switch fresh {
        case .failure(let error)?: result.error = error.message
        case .success?: break
        case nil: if result.updatedAt != previous.updatedAt { result.error = nil }
        }
        return result
    }
}
