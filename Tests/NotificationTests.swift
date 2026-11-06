import Foundation

@main
enum NotificationTests {
    @MainActor
    static func main() throws {
        try testResetBoundaryAndDeduplication()
        try testPruningUsesNumericTimestamps()
        print("Notification checks passed")
    }

    @MainActor
    private static func testResetBoundaryAndDeduplication() throws {
        let suite = "widget.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(95.0, forKey: Pref.threshold)
        defaults.set(false, forKey: Pref.notify)
        defaults.set(true, forKey: Pref.notifyReset)

        var notices: [(String, String)] = []
        let notifier = Notifier(defaults: defaults) { notices.append(($0, $1)) }
        let previousTime = Date(timeIntervalSince1970: 1_000)
        let observationTime = Date(timeIntervalSince1970: 1_100)
        // An unrelated publication advanced the whole snapshot after the
        // deadline; the window still contains its last measured 98% usage.
        let prior = snapshot(at: Date(timeIntervalSince1970: 1_075), usage: 98, deadline: 1_050)
        let rolled = snapshot(at: observationTime, usage: 6, deadline: 2_000)
        notifier.check(prev: prior, next: rolled)
        try expect(notices.count == 1, "real rollover should emit one notice")
        try expect(notices[0].0.contains("limit reset") || notices[0].0.contains("лимит сброшен"),
                   "reset title should identify the reset")
        try expect(notices[0].1.contains(Fmt.percent(6)), "notice should report actual 6% usage")

        let reloaded = Notifier(defaults: defaults) { notices.append(($0, $1)) }
        reloaded.check(prev: prior, next: rolled)
        try expect(notices.count == 1, "replay after reload should remain deduplicated")

        var correctionNotices: [(String, String)] = []
        let correctionSuite = "\(suite).correction"
        let correctionDefaults = UserDefaults(suiteName: correctionSuite)!
        defer { correctionDefaults.removePersistentDomain(forName: correctionSuite) }
        correctionDefaults.set(95.0, forKey: Pref.threshold)
        correctionDefaults.set(false, forKey: Pref.notify)
        correctionDefaults.set(true, forKey: Pref.notifyReset)
        let correctionNotifier = Notifier(defaults: correctionDefaults) {
            correctionNotices.append(($0, $1))
        }
        let notYetExpired = snapshot(at: previousTime, usage: 98, deadline: 1_500)
        let correctedFuture = snapshot(at: observationTime, usage: 6, deadline: 1_600)
        correctionNotifier.check(prev: notYetExpired, next: correctedFuture)
        let sameWindow = snapshot(at: observationTime, usage: 6, deadline: 1_050)
        correctionNotifier.check(prev: prior, next: sameWindow)
        let timestampLess = snapshot(at: previousTime, usage: 98, deadline: nil)
        let timestampLessNext = snapshot(at: observationTime, usage: 6, deadline: 2_000)
        correctionNotifier.check(prev: timestampLess, next: timestampLessNext)
        try expect(correctionNotices.isEmpty, "future corrections and timestamp-less windows are ambiguous")
    }

    @MainActor
    private static func testPruningUsesNumericTimestamps() throws {
        let suite = "widget.notifications.pruning.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = Set((100...400).map { timestamp in
            "reset|provider\(timestamp % 3)|window|\(timestamp)"
        })
        defaults.set(Array(keys), forKey: "notify.sent")
        defaults.set(false, forKey: Pref.notify)
        defaults.set(false, forKey: Pref.notifyReset)
        let notifier = Notifier(defaults: defaults) { _, _ in
            fatalError("empty snapshot must not post")
        }
        notifier.check(prev: .empty, next: Snapshot(providers: [], generatedAt: Date(timeIntervalSince1970: 500)))
        let retained = Set(defaults.stringArray(forKey: "notify.sent") ?? [])
        try expect(retained.count == 150, "more than 300 keys should trim to 150")
        try expect(retained.contains("reset|provider1|window|400"), "newest timestamp should survive")
        try expect(!retained.contains("reset|provider1|window|100"), "oldest timestamp should be pruned")
        try expect(retained.contains("reset|provider0|window|399"), "provider spelling must not drive recency")
    }

    private static func snapshot(at time: Date, usage: Double, deadline: TimeInterval?) -> Snapshot {
        Snapshot(providers: [ProviderStatus(provider: .claude, windows: [
            LimitWindow(name: "session", usedPercent: usage,
                        resetsAt: deadline.map { Date(timeIntervalSince1970: $0) }),
        ])], generatedAt: time)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
