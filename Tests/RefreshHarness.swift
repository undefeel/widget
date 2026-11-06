import Foundation

// Minimal compile-time stand-ins for production integrations. The exercised
// Store always receives synthetic operations, so no CLI, history, VPN, disk,
// notifications, or WidgetKit effects are reachable from this executable.
enum Pref {
    static let requireVPN = "requireVPN"
    static let fastPoll = "poll.fast"
    static let threshold = "notify.threshold"
    static func register() {}
}

enum VPN { static func isActive() -> Bool { false } }

enum ClaudeFetcher {
    static func fetchCLI() -> Result<ProviderStatus, FetchError>? { nil }
    static func fromStatusline() -> ProviderStatus? { nil }
}

enum CodexFetcher {
    static func fetchCLI() -> Result<ProviderStatus, FetchError>? { nil }
    static func fromSessionLogs() -> ProviderStatus? { nil }
}

enum AntigravityFetcher {
    static func fetchCLI() -> Result<ProviderStatus, FetchError>? { nil }
}

enum UsageScanner { static func scan() -> UsageStats? { nil } }

@MainActor final class Notifier {
    static let shared = Notifier()
    func check(prev: Snapshot, next: Snapshot) {}
}

struct FetchError: Error { let message: String; init(_ message: String) { self.message = message } }

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read<R>(_ body: (Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(value) }
    func mutate<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

private final class Gate: @unchecked Sendable {
    private let name: String
    private let semaphore = DispatchSemaphore(value: 0)
    private let started = DispatchSemaphore(value: 0)
    init(_ name: String) { self.name = name }
    func enterAndWait() { started.signal(); semaphore.wait() }
    func waitUntilStarted() { precondition(started.wait(timeout: .now() + 5) == .success, "\(name) operation did not start") }
    func release() { semaphore.signal() }
}

@MainActor private func eventually(_ description: String, _ predicate: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    precondition(predicate(), "timed out waiting for \(description)")
}

private func usage(_ amount: Int) -> UsageStats {
    UsageStats(dayStarts: [Date()], models: [ModelUsage(model: "synthetic", provider: .codex,
        days: [amount], sessions: 1)], sessionsToday: 1, generatedAt: Date())
}

private func status(_ provider: Provider, _ percent: Double, _ at: Date = Date()) -> ProviderStatus {
    ProviderStatus(provider: provider, windows: [LimitWindow(name: "synthetic", usedPercent: percent,
        resetsAt: nil)], updatedAt: at, source: "synthetic")
}

private struct Captures {
    let reads: Locked<[String: Int]>
    let saves: Locked<[Snapshot]>
    let reloads: Locked<Int>
    let notifications: Locked<Int>
}

@MainActor private func makeStore(
    snapshot: Snapshot = .empty,
    vpn: Locked<Bool> = Locked(true),
    vpnWork: (@Sendable () -> Bool)? = nil,
    usageWork: @escaping @Sendable () -> UsageStats? = { usage(7) },
    fetchWork: @escaping @Sendable (Provider) -> Result<ProviderStatus, FetchError>? = { .success(status($0, 23)) },
    fallbackWork: @escaping @Sendable (Provider) -> ProviderStatus? = { _ in nil }
) -> (LimitsStore, Captures) {
    let reads = Locked<[String: Int]>([:])
    let saves = Locked<[Snapshot]>([])
    let reloads = Locked(0)
    let notifications = Locked(0)
    let operations = RefreshOperations(
        vpnAllowed: vpnWork ?? { vpn.read { $0 } },
        fetch: { provider in reads.mutate { $0["fetch-\(provider.rawValue)", default: 0] += 1 }; return fetchWork(provider) },
        fallback: { provider in reads.mutate { $0["fallback-\(provider.rawValue)", default: 0] += 1 }; return fallbackWork(provider) },
        usage: { reads.mutate { $0["usage", default: 0] += 1 }; return usageWork() },
        save: { snapshot in saves.mutate { $0.append(snapshot) } },
        notify: { _, _ in notifications.mutate { $0 += 1 } },
        reloadWidgets: { reloads.mutate { $0 += 1 } }
    )
    return (LimitsStore(snapshot: snapshot, operations: operations),
            Captures(reads: reads, saves: saves, reloads: reloads, notifications: notifications))
}

@MainActor private func waitForLimits(_ store: LimitsStore) async {
    await eventually("limits completion") { !store.isRefreshing }
}

@MainActor private func testLimitsBeforeUsage() async {
    let gate = Gate("usage")
    let (store, captures) = makeStore(usageWork: { gate.enterAndWait(); return usage(41) })
    let start = Date()
    let refresh = Task { await store.refresh(force: true) }
    await eventually("usage scan start") { captures.reads.read { $0["usage", default: 0] == 1 } }
    gate.waitUntilStarted()
    await waitForLimits(store)
    let limitsElapsed = Date().timeIntervalSince(start)
    precondition(limitsElapsed < 5, "limits waited for held statistics operation")
    precondition(store.snapshot.status(.claude).headline() == 23, "limits were not published before statistics")
    precondition(store.snapshot.usage == nil, "held statistics unexpectedly completed")
    precondition(captures.reloads.read { $0 } > 0, "limits publication did not reload widget")
    gate.release()
    await refresh.value
    await eventually("late usage publication") { store.snapshot.usage?.total == 41 }
    precondition(store.snapshot.status(.claude).headline() == 23, "late usage reverted provider limits")
    print("limits-first: provider snapshot published in \(Int(limitsElapsed * 1000))ms while statistics gate remained held")
}

@MainActor private func testUsageBeforeLimitsAndOverlap() async {
    let usageGate = Gate("usage"), fetchGate = Gate("provider")
    let (store, captures) = makeStore(
        usageWork: { usageGate.enterAndWait(); return usage(52) },
        fetchWork: { provider in
            if provider == .claude { fetchGate.enterAndWait() }
            return .success(status(provider, 37))
        })
    let first = Task { await store.refresh(force: true) }
    await eventually("overlap work start") {
        captures.reads.read { $0["usage", default: 0] == 1 && $0["fetch-claude", default: 0] == 1 }
    }
    usageGate.waitUntilStarted(); fetchGate.waitUntilStarted()
    async let wake = store.refresh(force: true)
    async let timer = store.refresh(force: false)
    async let manual = store.refresh(force: true)
    _ = await (wake, timer, manual)
    precondition(captures.reads.read { $0["usage", default: 0] } == 1, "overlap duplicated usage scan")
    for provider in Provider.allCases {
        precondition(captures.reads.read { $0["fetch-\(provider.rawValue)", default: 0] } == 1,
                     "overlap duplicated \(provider.rawValue) provider process")
    }
    usageGate.release()
    await eventually("usage-first publication") { store.snapshot.usage?.total == 52 }
    fetchGate.release()
    await first.value
    await waitForLimits(store)
    precondition(store.snapshot.usage?.total == 52, "late limits reverted newer usage")
    precondition(store.snapshot.status(.claude).headline() == 37, "limits result was lost")
}

@MainActor private func testVPNFenceAndPersistedState() async {
    let fetchGate = Gate("provider"), usageGate = Gate("usage")
    let fetchCalls = Locked(0), usageCalls = Locked(0)
    let fetchCompletions = Locked(0), usageCompletions = Locked(0)
    let vpn = Locked(true)
    let old = status(.claude, 11)
    let starting = Snapshot(providers: [old], generatedAt: Date(), usage: usage(5))
    let (store, captures) = makeStore(snapshot: starting, vpn: vpn,
        usageWork: {
            let call = usageCalls.mutate { count -> Int in count += 1; return count }
            if call == 1 { usageGate.enterAndWait() }
            let result = usage(call == 1 ? 99 : 100)
            usageCompletions.mutate { $0 += 1 }
            return result
        }, fetchWork: { provider in
            if provider == .claude {
                let call = fetchCalls.mutate { count -> Int in count += 1; return count }
                if call == 1 { fetchGate.enterAndWait() }
                fetchCompletions.mutate { $0 += 1 }
            }
            return .success(status(provider, 88))
        })
    let first = Task { await store.refresh(force: true) }
    await eventually("VPN test operations start") {
        captures.reads.read { $0["fetch-claude", default: 0] == 1 && $0["usage", default: 0] == 1 }
    }
    fetchGate.waitUntilStarted(); usageGate.waitUntilStarted()
    vpn.mutate { $0 = false }
    await store.refresh(force: false)
    precondition(store.snapshot.paused == LimitsStore.vpnOffMessage, "VPN block did not publish pause")
    precondition(store.snapshot.status(.claude).headline() == 11, "blocked refresh changed provider state")
    precondition(captures.reads.read { $0["usage", default: 0] } == 1, "initial usage did not start")
    let blockedReads = captures.reads.read { $0 }
    await store.refresh(force: true)
    precondition(captures.reads.read { $0 } == blockedReads, "VPN-blocked call started reads")
    fetchGate.release()
    usageGate.release()
    await first.value
    await eventually("stale limits completion") { !store.isRefreshing }
    await eventually("invalidated work settlement") {
        fetchCompletions.read { $0 } == 1 && usageCompletions.read { $0 } == 1
    }
    precondition(store.snapshot.paused == LimitsStore.vpnOffMessage, "late completion cleared VPN pause")
    precondition(store.snapshot.status(.claude).headline() == 11, "late completion replaced superseded limits")
    precondition(store.snapshot.usage?.total == 5, "late usage completion replaced prior statistics while VPN was paused")
    let persisted = captures.saves.read { $0.last }
    precondition(persisted == store.snapshot, "saved snapshot differs from paused state")
    precondition(captures.reloads.read { $0 } > 0, "pause snapshot was not widget-visible")
    vpn.mutate { $0 = true }
    await store.refresh(force: true)
    await waitForLimits(store)
    await eventually("resumed usage publication") {
        store.snapshot.paused == nil && store.snapshot.usage?.total == 100
    }
    precondition(fetchCalls.read { $0 } == 2, "VPN resume did not start a fresh provider request")
    precondition(usageCalls.read { $0 } == 2, "VPN resume did not start a fresh usage scan")
    precondition(store.snapshot.status(.claude).headline() == 88,
                 "VPN resume did not publish fresh provider data")
    precondition(store.snapshot.paused == nil, "successful VPN resume left the snapshot paused")
    await eventually("resumed persisted and widget snapshot") {
        let saved = captures.saves.read { $0.last }
        return saved == store.snapshot && saved?.paused == nil
            && saved?.status(.claude).headline() == 88 && saved?.usage?.total == 100
            && captures.reloads.read { $0 } >= 2
    }
}

@MainActor private func testFallbackAndUnchangedPayload() async {
    let previous = status(.claude, 61, Date(timeIntervalSince1970: 100))
    let previousCodex = status(.codex, 33, Date(timeIntervalSince1970: 110))
    let initial = Snapshot(providers: [previous, previousCodex], generatedAt: Date(timeIntervalSince1970: 123), usage: usage(8))
    let fallback = status(.claude, 72, Date(timeIntervalSince1970: 200))
    let (store, captures) = makeStore(snapshot: initial,
        fetchWork: { provider in provider == .antigravity ? .success(status(provider, 0)) : .failure(FetchError("synthetic failure")) },
        fallbackWork: { provider in provider == .claude ? fallback : nil })
    await store.refresh(force: true)
    await waitForLimits(store)
    precondition(store.snapshot.status(.claude).headline() == 72, "failure fallback was not selected")
    precondition(store.snapshot.status(.claude).error == "synthetic failure", "CLI error was not retained")
    precondition(store.snapshot.status(.codex).headline() == 33, "temporary failure discarded prior provider data")
    precondition(store.snapshot.status(.codex).error == "synthetic failure", "second CLI error was not retained")
    precondition(captures.reads.read { $0["fallback-claude", default: 0] } == 1, "fallback was not lazy on failure")
    precondition(captures.reads.read { $0["fallback-codex", default: 0] } == 1, "Codex history fallback was not lazy on failure")
    precondition(captures.reads.read { $0["fallback-antigravity", default: 0] } == 0, "Antigravity unexpectedly ran a fallback")

    let stable = store.snapshot
    let (unchanged, untouched) = makeStore(snapshot: stable,
        usageWork: { stable.usage },
        fetchWork: { provider in .success(stable.status(provider)) })
    // Seed generation equality is established by returning an identical payload;
    // no save/reload should occur when refresh observes no data change.
    await unchanged.refresh(force: true)
    await waitForLimits(unchanged)
    precondition(untouched.saves.read { $0.isEmpty }, "unchanged payload was persisted")
    precondition(untouched.reloads.read { $0 == 0 }, "unchanged payload reloaded widgets")
    precondition(unchanged.snapshot.generatedAt == stable.generatedAt, "unchanged payload advanced generatedAt")
}

@MainActor private func testFastProviderBeforeSlowProviderAndUsage() async {
    let slowProvider = Gate("slow provider"), slowUsage = Gate("slow usage")
    let initial = Snapshot(providers: Provider.allCases.map { status($0, 0) }, generatedAt: Date())
    let (store, _) = makeStore(snapshot: initial,
        usageWork: { slowUsage.enterAndWait(); return usage(66) },
        fetchWork: { provider in
            if provider == .claude { slowProvider.enterAndWait() }
            return .success(status(provider, provider == .codex ? 44 : 31))
        })
    let refresh = Task { await store.refresh(force: true) }
    await eventually("fast Codex publication") { store.snapshot.status(.codex).headline() == 44 }
    slowProvider.waitUntilStarted(); slowUsage.waitUntilStarted()
    let publishedBeforeSlowWork = store.snapshot.status(.codex).headline() == 44
    let indicatorStayedActive = store.isRefreshing
    slowProvider.release(); slowUsage.release()
    await refresh.value
    await waitForLimits(store)
    await eventually("slow usage completion") { store.snapshot.usage?.total == 66 }
    precondition(publishedBeforeSlowWork,
                 "fast Codex result waited for the unrelated provider batch and usage scan")
    precondition(indicatorStayedActive,
                 "limits refresh indicator ended before the slow provider batch completed")
}

@MainActor private func testStaleAllowedGateCannotStartWork() async {
    let firstGate = Gate("first VPN gate")
    let gateCalls = Locked(0)
    let (store, captures) = makeStore(vpnWork: {
        let call = gateCalls.mutate { count -> Int in count += 1; return count }
        if call == 1 { firstGate.enterAndWait(); return true }
        return false
    })
    let olderRefresh = Task { await store.refresh(force: true) }
    await eventually("first VPN gate entry") { gateCalls.read { $0 == 1 } }
    firstGate.waitUntilStarted()

    // This newer policy observation blocks while the older allowed read is
    // suspended. Releasing that stale result must not clear pause or start IO.
    await store.refresh(force: true)
    precondition(store.snapshot.paused == LimitsStore.vpnOffMessage,
                 "newer VPN block was not published")
    firstGate.release()
    await olderRefresh.value
    await eventually("stale gate settlement") { !store.isRefreshing }
    precondition(store.snapshot.paused == LimitsStore.vpnOffMessage,
                 "stale allowed VPN result cleared the newer pause")
    precondition(captures.reads.read { $0.isEmpty },
                 "stale allowed VPN result started provider or history reads")
    precondition(captures.saves.read { $0.last } == store.snapshot,
                 "persisted snapshot omitted the newer VPN pause")
    precondition(captures.reloads.read { $0 } > 0,
                 "newer VPN pause was not widget-visible")
}

@main struct RefreshHarness {
    @MainActor static func main() async {
        let skipIncrementalProvider = CommandLine.arguments.dropFirst().contains("--skip-incremental-provider")
        precondition(CommandLine.arguments.count == (skipIncrementalProvider ? 2 : 1), "unknown refresh harness argument")
        UserDefaults.standard.set(false, forKey: Pref.fastPoll)
        UserDefaults.standard.set(95.0, forKey: Pref.threshold)
        await testLimitsBeforeUsage()
        await testUsageBeforeLimitsAndOverlap()
        await testVPNFenceAndPersistedState()
        await testFallbackAndUnchangedPayload()
        await testStaleAllowedGateCannotStartWork()
        if !skipIncrementalProvider { await testFastProviderBeforeSlowProviderAndUsage() }
        print("refresh harness passed")
    }
}
