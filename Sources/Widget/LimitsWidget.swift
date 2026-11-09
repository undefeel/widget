import SwiftUI
import WidgetKit

struct LimitsEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
}

struct LimitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry {
        LimitsEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (LimitsEntry) -> Void) {
        completion(LimitsEntry(date: Date(), snapshot: SnapshotIO.load() ?? (context.isPreview ? .preview : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsEntry>) -> Void) {
        let snap = SnapshotIO.load()
        let now = Date()
        // Записи каждые 5 минут, чтобы проценты обнулялись после сброса окна даже без перезагрузки.
        let entries = (0..<12).map { LimitsEntry(date: now.addingTimeInterval(Double($0) * 300), snapshot: snap) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

extension Snapshot {
    static var preview: Snapshot {
        let now = Date()
        return Snapshot(providers: [
            ProviderStatus(provider: .claude, windows: [
                LimitWindow(name: "5 часов", usedPercent: 42, resetsAt: now.addingTimeInterval(7800)),
                LimitWindow(name: "Неделя", usedPercent: 23, resetsAt: now.addingTimeInterval(300000)),
            ], updatedAt: now),
            ProviderStatus(provider: .codex, windows: [
                LimitWindow(name: "5 часов", usedPercent: 15, resetsAt: now.addingTimeInterval(9000)),
                LimitWindow(name: "Неделя", usedPercent: 18, resetsAt: now.addingTimeInterval(400000)),
            ], updatedAt: now),
            ProviderStatus(provider: .antigravity, windows: [
                LimitWindow(name: "Gemini 3 Pro", usedPercent: 80, resetsAt: now.addingTimeInterval(5000)),
                LimitWindow(name: "Claude Sonnet", usedPercent: 20, resetsAt: now.addingTimeInterval(5000)),
            ], updatedAt: now),
        ], generatedAt: now, cheapVibe: BalanceStatus(tokens: 173_400_000, updatedAt: now, error: nil))
    }
}

// MARK: - Views

private struct BalanceFooter: View {
    let balance: BalanceStatus?
    let now: Date
    var compact = false

    var body: some View {
        if let tokens = balance?.tokens {
            let amount = compact ? Fmt.tokens(tokens) : LF("Остаток: %@", Fmt.tokens(tokens))
            let accessibilityLabel = "\(L("Токены CheapVibeCode")): \(amount)"
            let details = [balance?.localizedError,
                           balance?.updatedAt.map { Fmt.ago($0, now: now) }]
                .compactMap { $0 }.joined(separator: " · ")
            HStack(spacing: 4) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("CheapVibeCode")
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(amount)
                    .font(.system(size: 9).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(details)
            .help(details)
        }
    }
}

struct LimitsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LimitsEntry
    var narrowest = false

    var body: some View {
        Group {
            if let snap = entry.snapshot {
                Group {
                    switch family {
                    case .systemSmall where narrowest: NarrowestView(snapshot: snap, now: entry.date)
                    case .systemSmall: SmallView(snapshot: snap, now: entry.date)
                    case .systemLarge, .systemExtraLarge: LargeView(snapshot: snap, now: entry.date)
                    default: MediumView(snapshot: snap, now: entry.date)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if snap.paused != nil {
                        Image(systemName: "shield.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help(L(snap.paused ?? ""))
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.33percent").font(.title2)
                    Text("Запусти AILimits").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct SmallView: View {
    let snapshot: Snapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Агенты").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            ForEach(Provider.allCases) { p in
                let h = snapshot.status(p).headline(at: now)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(p.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(Fmt.percent(h)).font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(h.map(Fmt.levelText) ?? .secondary)
                    }
                    LimitBar(used: h ?? 0, tint: p.tint)
                }
            }
            if snapshot.cheapVibe?.tokens != nil {
                Divider()
                BalanceFooter(balance: snapshot.cheapVibe, now: now, compact: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MediumView: View {
    let snapshot: Snapshot
    let now: Date

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Provider.allCases) { p in
                    let s = snapshot.status(p)
                    VStack(spacing: 5) {
                        LimitRing(used: s.headline(at: now), tint: p.tint, size: 66)
                        Text(p.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(s.windows.isEmpty ? (s.error ?? L("нет данных"))
                             : s.windows.prefix(2).map { "\(Fmt.windowShort($0.name)) \(Fmt.percent($0.effectiveUsed(at: now)))" }
                                .joined(separator: " · "))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            if snapshot.cheapVibe?.tokens != nil {
                Divider()
                BalanceFooter(balance: snapshot.cheapVibe, now: now)
            }
        }
    }
}

private struct LargeView: View {
    let snapshot: Snapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("Агенты").font(.system(size: 15, weight: .bold))
                Spacer()
                Text(Fmt.ago(snapshot.generatedAt, now: now)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Provider.allCases) { p in
                let s = snapshot.status(p)
                let h = s.headline(at: now)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        ProviderIcon(provider: p, size: 18)
                        Text(p.title).font(.system(size: 13, weight: .semibold))
                        if let d = s.detail {
                            Text(d.replacingOccurrences(of: "План ", with: "")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.percent(h)).font(.system(size: 15, weight: .bold).monospacedDigit())
                            .foregroundStyle(h.map(Fmt.levelText) ?? .secondary)
                    }
                    if s.windows.isEmpty {
                        Text(s.error ?? L("нет данных")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(s.windows.prefix(3)) { w in
                        let used = w.effectiveUsed(at: now)
                        HStack(spacing: 8) {
                            Text(Fmt.window(w.name)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading).lineLimit(1)
                            LimitBar(used: used, tint: p.tint)
                            Text(Fmt.percent(used)).fontWeight(.semibold).frame(width: 34, alignment: .trailing)
                        }
                        .font(.system(size: 11).monospacedDigit())
                    }
                }
            }
            let hasBalance = snapshot.cheapVibe?.tokens != nil
            let usage = snapshot.usage.flatMap { $0.total > 0 ? $0 : nil }
            if hasBalance || usage != nil {
                Spacer(minLength: 0)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    if hasBalance {
                        BalanceFooter(balance: snapshot.cheapVibe, now: now)
                    }
                    if let u = usage {
                        HStack(spacing: 6) {
                            Image(systemName: "chart.xyaxis.line")
                            Text([LF("%@ токенов за неделю", Fmt.tokens(u.total)), u.top.map { LF("чаще всего %@", $0.model) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Маленький виджет: лимит, который закончится первым.
private struct NarrowestView: View {
    let snapshot: Snapshot
    let now: Date

    var body: some View {
        let all = snapshot.providers.flatMap { s in s.windows.map { (s.provider, $0) } }
        if let (p, w) = all.max(by: { $0.1.effectiveUsed(at: now) < $1.1.effectiveUsed(at: now) }) {
            let used = w.effectiveUsed(at: now)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ProviderIcon(provider: p, size: 18)
                    Text(p.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                Text(Fmt.percent(used))
                    .font(.system(size: 42, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Fmt.levelText(used))
                    .padding(.top, 8)
                Text(Fmt.window(w.name)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if let r = Fmt.resetIn(w.resetsAt, now: now) {
                    Text(r).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("нет данных").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Widget

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AILimitsWidget", provider: LimitsProvider()) { entry in
            LimitsWidgetView(entry: entry)
        }
        .configurationDisplayName("Лимиты AI")
        .description(L("Лимиты Claude, Codex и Antigravity и баланс CheapVibeCode."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NarrowestWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AILimitsNarrowest", provider: LimitsProvider()) { entry in
            LimitsWidgetView(entry: entry, narrowest: true)
        }
        .configurationDisplayName("Самый узкий лимит")
        .description("Лимит, который закончится первым.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct AILimitsWidgetBundle: WidgetBundle {
    var body: some Widget {
        LimitsWidget()
        NarrowestWidget()
    }
}
