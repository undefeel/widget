import AppKit
import Charts
import SwiftUI

/// Локальное состояние вью. `@State` в этом SDK — макрос, а его плагина нет в Command Line Tools.
final class StateBox<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Системные стили (Liquid Glass на macOS 26+, обычные — раньше)

extension View {
    @ViewBuilder
    func glassButton(circle: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(circle ? .circle : .capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(circle ? .circle : .capsule)
        }
    }

    /// Блок-секция внутри панели: затемняет стекло под собой, как группа в системных настройках.
    func section(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.sectionFill))
    }
}

extension Color {
    static let sectionFill = Color(nsColor: NSColor(name: nil) { ap in
        NSColor(white: 0, alpha: ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.22 : 0.05)
    })
}

struct PopoverView: View {
    @EnvironmentObject private var panel: PanelState

    var body: some View {
        Group {
            switch panel.page {
            case .main: MainPanel()
            case .stats: UsageView()
            }
        }
        .padding(12)
        .frame(width: panel.page == .main ? 360 : 600)
    }
}

// MARK: - Главная страница

private struct MainPanel: View {
    @EnvironmentObject private var store: LimitsStore
    @EnvironmentObject private var panel: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Агенты").font(.headline)
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Обновить") { Task { await store.refresh(force: true) } }
                }
                IconButton(symbol: "gearshape", help: "Настройки") { panel.openSettings() }
            }
            .padding(.horizontal, 4)

            SummaryRow()

            if let paused = store.snapshot.paused {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(paused)).fontWeight(.semibold)
                        Text("Показаны последние данные. Опрос продолжится, как только VPN включится.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "shield.slash.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .section()
            }

            BalanceSection()

            ForEach(Provider.allCases) { p in
                ProviderSection(status: store.snapshot.status(p), now: store.now)
            }

            HStack(spacing: 6) {
                ForEach(Provider.allCases) { p in
                    Button { panel.launch(p) } label: {
                        Label(p.command, systemImage: "apple.terminal")
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .controlSize(.large)
                    .help(LF("Запустить %@", p.agentTitle))
                }
            }

            HStack {
                Text(panel.status ?? LF("Обновлено %@", Fmt.ago(store.snapshot.generatedAt, now: store.now)))
                    .lineLimit(1)
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .glassButton(circle: true)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// Строка-сводка: сама листает факты о неделе, по клику открывает статистику.
private struct SummaryRow: View {
    @EnvironmentObject private var store: LimitsStore
    @EnvironmentObject private var panel: PanelState
    private let period: TimeInterval = 4.5

    var body: some View {
        let items = summaries
        Button { panel.page = .stats } label: {
            TimelineView(.periodic(from: .now, by: period)) { ctx in
                let i = items.isEmpty ? 0 : Int(ctx.date.timeIntervalSinceReferenceDate / period) % items.count
                HStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(.tint)
                    Text(items.isEmpty ? L("Считаю токены…") : items[i])
                        .lineLimit(1)
                        .id(i)
                        .transition(.opacity)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .animation(.easeInOut(duration: 0.25), value: i)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .section(padding: 10)
        }
        .buttonStyle(.plain)
        .help("Статистика токенов")
    }

    private var summaries: [String] {
        var out: [String] = []
        let now = store.now
        if let u = store.snapshot.usage, u.total > 0 {
            out.append(LF("%@ токенов за неделю", Fmt.tokens(u.total)))
            if let top = u.top {
                out.append(LF("Чаще всего: %@ — %d%%", top.model, Int((Double(top.weekTotal) / Double(u.total) * 100).rounded())))
            }
            if u.sessionsToday > 0 { out.append(LF("Сессий сегодня: %d", u.sessionsToday)) }
        }
        let resets = store.snapshot.providers.flatMap { s in
            s.windows.compactMap { w in w.resetsAt.flatMap { $0 > now ? (s.provider, $0) : nil } }
        }
        if let n = resets.min(by: { $0.1 < $1.1 }) {
            out.append(LF("Ближайший сброс: %@ через %@", n.0.title, Fmt.duration(n.1.timeIntervalSince(now))))
        }
        return out
    }
}

/// Карточка баланса CheapVibeCode: бренд, компактный остаток, возраст и ошибка.
private struct BalanceSection: View {
    @EnvironmentObject private var store: LimitsStore

    private var balance: BalanceStatus? { store.snapshot.cheapVibe }

    var body: some View {
        if let balance, balance.tokens != nil || balance.error != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    Text("CheapVibeCode").fontWeight(.bold).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if let tokens = balance.tokens {
                        Text(LF("Остаток: %@", Fmt.tokens(tokens)))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                    }
                }
                if let error = balance.localizedError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let updatedAt = balance.updatedAt {
                    Text(Fmt.ago(updatedAt, now: store.now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .section()
            .accessibilityElement(children: .combine)
            .help(helpText(balance))
        }
    }

    /// Точная сумма с группировкой разрядов и, при наличии, ошибка/возраст.
    private func helpText(_ balance: BalanceStatus) -> String {
        var parts: [String] = []
        if let tokens = balance.tokens {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if let exact = formatter.string(from: NSNumber(value: tokens)) {
                parts.append(LF("Остаток: %@", exact))
            }
        }
        if let error = balance.localizedError { parts.append(error) }
        if let updatedAt = balance.updatedAt { parts.append(Fmt.ago(updatedAt, now: store.now)) }
        return parts.joined(separator: " · ")
    }
}

/// Агент: подпись над секцией и по полоске `Gauge` на каждое окно лимита.
struct ProviderSection: View {
    let status: ProviderStatus
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                ProviderIcon(provider: status.provider, size: 14)
                Text(status.provider.title).fontWeight(.semibold).foregroundStyle(.primary)
                if let d = status.detail { Text(d.replacingOccurrences(of: "План ", with: "")) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)

            VStack(alignment: .leading, spacing: 10) {
                if status.windows.isEmpty {
                    Text(status.error ?? L("Нет данных")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(status.windows) { w in
                    WindowGauge(window: w, tint: status.provider.tint, now: now)
                }
                if !status.windows.isEmpty, let e = status.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .section()
        }
        .help([status.source.map(L), Fmt.ago(status.updatedAt, now: now)].compactMap { $0 }.joined(separator: " · "))
    }
}

private struct WindowGauge: View {
    let window: LimitWindow
    let tint: Color
    let now: Date

    var body: some View {
        let used = window.effectiveUsed(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.window(window.name)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Fmt.percent(used)).fontWeight(.semibold).foregroundStyle(Fmt.levelText(used))
            }
            .font(.callout.monospacedDigit())
            LimitBar(used: used, tint: tint)
            if let r = Fmt.resetIn(window.resetsAt, now: now) {
                Text(r.prefix(1).uppercased() + r.dropFirst()).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .help(LF("%@: использовано %@", Fmt.window(window.name), String(format: "%.1f%%", used)))
    }
}

// MARK: - Статистика токенов

private struct UsageView: View {
    enum Period: Hashable { case week, month }

    @EnvironmentObject private var store: LimitsStore
    @EnvironmentObject private var panel: PanelState
    @StateObject private var periodBox = StateBox(Period.week)
    @StateObject private var filterBox = StateBox<Provider?>(nil)
    @StateObject private var selectedBox = StateBox<String?>(nil)
    @StateObject private var sortBox = StateBox([KeyPathComparator(\Row.tokens, order: .reverse)])
    private var filter: Provider? { filterBox.value }
    private var period: Period { periodBox.value }

    /// Столбец графика: день (режим «7 дней») или календарная неделя («Месяц»).
    struct Bucket {
        let label: String
        let title: String
        let days: Range<Int>
    }

    struct Series: Identifiable {
        let id: String
        let agent: String
        /// По столбцам графика.
        let values: [Int]
        let sessions: Int
        let color: Color
        var total: Int { values.reduce(0, +) }
    }

    struct Row: Identifiable {
        let id: String
        let agent: String
        let tokens: Int
        let share: Double
        let sessions: Int
        let color: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left", help: "Назад") { panel.page = .main }
                Text(period == .week ? "Токены за 7 дней" : "Токены по неделям").font(.headline)
                Spacer()
                Picker("Период", selection: Binding(get: { periodBox.value },
                                                    set: { periodBox.value = $0; selectedBox.value = nil })) {
                    Text("7 дней").tag(Period.week)
                    Text("Месяц").tag(Period.month)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Picker("Агент", selection: $filterBox.value) {
                Text("Все").tag(Provider?.none)
                Text("Claude").tag(Provider?.some(.claude))
                Text("Codex").tag(Provider?.some(.codex))
                Text("Antigravity").tag(Provider?.some(.antigravity))
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let u = store.snapshot.usage, u.models.contains(where: { $0.days.contains { $0 > 0 } }) {
                content(u)
            } else {
                Text(store.snapshot.usage == nil ? L("Считаю токены…") : L("За неделю токенов не найдено"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            }

            Text("Вход, запись в кэш и выход, без чтения из кэша. По локальным логам Claude Code, Codex и Antigravity.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func buckets(_ u: UsageStats) -> [Bucket] {
        let n = u.dayStarts.count
        switch period {
        case .week:
            return (max(0, n - 7)..<n).map {
                Bucket(label: Fmt.day(u.dayStarts[$0]), title: Fmt.day(u.dayStarts[$0], long: true), days: $0..<$0 + 1)
            }
        case .month:
            let cal = Calendar.current
            var out: [Bucket] = []
            var lo = 0
            for i in 0..<n where i == n - 1 || cal.component(.weekOfYear, from: u.dayStarts[i + 1]) != cal.component(.weekOfYear, from: u.dayStarts[i]) {
                let first = u.dayStarts[lo]
                let last = cal.date(byAdding: .day, value: 6, to: first) ?? u.dayStarts[i]
                out.append(Bucket(label: Fmt.dayMonth(first),
                                  title: "\(Fmt.dayMonth(first)) – \(Fmt.dayMonth(last))",
                                  days: lo..<i + 1))
                lo = i + 1
            }
            return out
        }
    }

    private func series(_ u: UsageStats, _ b: [Bucket]) -> [Series] {
        func values(_ m: ModelUsage) -> [Int] { b.map { r in r.days.reduce(0) { $0 + (m.days.indices.contains($1) ? m.days[$1] : 0) } } }
        func sessions(_ m: ModelUsage) -> Int { period == .week ? m.sessions : (m.sessionsMonth ?? m.sessions) }
        let all = u.models.enumerated().filter { filter == nil || $0.element.provider == filter }
        var out = all.prefix(Palette.count).map { i, m in
            Series(id: m.model, agent: m.provider.title, values: values(m), sessions: sessions(m), color: Palette.color(i))
        }
        let rest = all.dropFirst(Palette.count).map(\.element)
        if !rest.isEmpty {
            let v = b.indices.map { k in rest.reduce(0) { $0 + values($1)[k] } }
            out.append(Series(id: L("Другие"), agent: "—", values: v, sessions: rest.reduce(0) { $0 + sessions($1) },
                              color: Palette.other))
        }
        return out.filter { $0.total > 0 }
    }

    @ViewBuilder
    private func content(_ u: UsageStats) -> some View {
        let b = buckets(u)
        let s = series(u, b)
        let totals = b.indices.map { k in s.reduce(0) { $0 + $1.values[k] } }
        let sum = totals.reduce(0, +)
        let peak = totals.indices.max { totals[$0] < totals[$1] } ?? 0
        let days = b.reduce(0) { $0 + $1.days.count }

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            stat(period == .week ? "Всего за неделю" : "Всего за 5 недель", Fmt.tokens(sum))
            stat(period == .week ? "В среднем за день" : "В среднем за неделю",
                 Fmt.tokens(period == .week ? sum / max(1, days) : sum * 7 / max(1, days)))
            stat(period == .week ? "Пиковый день" : "Пиковая неделя", "\(b[peak].label) · \(Fmt.tokens(totals[peak]))")
            stat("Чаще всего", s.max { $0.total < $1.total }?.id ?? "—")
        }

        chart(b, s, totals: totals).section()

        table(s, sum: sum)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(.title3, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
        }
        .section(padding: 10)
    }

    private func chart(_ b: [Bucket], _ s: [Series], totals: [Int]) -> some View {
        let selected = selectedBox.value.flatMap { label in b.firstIndex { $0.label == label } }
        return Chart {
            ForEach(s) { ser in
                ForEach(b.indices, id: \.self) { i in
                    BarMark(x: .value("Период", b[i].label), y: .value("Токены", ser.values[i]), width: .ratio(0.55))
                        .foregroundStyle(by: .value("Модель", ser.id))
                }
            }
            if let i = selected {
                RuleMark(x: .value("Период", b[i].label))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(b[i], s, index: i, total: totals[i])
                    }
            }
        }
        .chartForegroundStyleScale(domain: s.map(\.id), range: s.map(\.color))
        .chartXAxis { AxisMarks { _ in AxisValueLabel() } }
        .chartYAxis {
            AxisMarks(position: .trailing) { v in
                AxisGridLine()
                AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.tokens(n)) } }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let p) = phase, let plot = proxy.plotFrame {
                            selectedBox.value = proxy.value(atX: p.x - geo[plot].origin.x, as: String.self)
                        } else {
                            selectedBox.value = nil
                        }
                    }
            }
        }
        .frame(height: 240)
        .accessibilityLabel(Text(period == .week ? "Токены по дням" : "Токены по неделям"))
    }

    private func tooltip(_ bucket: Bucket, _ s: [Series], index i: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bucket.title).fontWeight(.semibold)
                Spacer(minLength: 12)
                Text(Fmt.tokens(total)).fontWeight(.semibold)
            }
            ForEach(s.filter { $0.values[i] > 0 }) { ser in
                HStack(spacing: 6) {
                    Circle().fill(ser.color).frame(width: 7, height: 7)
                    Text(ser.id).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(Fmt.tokens(ser.values[i]))
                }
            }
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    /// Таблица моделей: сетка в стиле списков системных настроек, сортировка кликом по заголовку.
    private func table(_ s: [Series], sum: Int) -> some View {
        let rows = s.map { ser in
            Row(id: ser.id, agent: ser.agent, tokens: ser.total, share: sum > 0 ? Double(ser.total) / Double(sum) : 0,
                sessions: ser.sessions, color: ser.color)
        }.sorted(using: sortBox.value)
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                header("Модель", \.id)
                header("Агент", \.agent)
                header("Токены", \.tokens).gridColumnAlignment(.trailing)
                header("Доля", \.share).gridColumnAlignment(.trailing)
                header("Сессии", \.sessions).gridColumnAlignment(.trailing)
            }
            .padding(.bottom, 6)
            ForEach(rows) { r in
                Divider()
                GridRow {
                    HStack(spacing: 7) {
                        Circle().fill(r.color).frame(width: 8, height: 8)
                        Text(r.id).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(r.agent).foregroundStyle(.secondary).lineLimit(1)
                    Text(Fmt.tokens(r.tokens)).fontWeight(.medium)
                    Text("\(Int((r.share * 100).rounded()))%").foregroundStyle(.secondary)
                    Text("\(r.sessions)").foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .font(.callout.monospacedDigit())
        .section()
    }

    private func header<V: Comparable>(_ title: LocalizedStringKey, _ key: KeyPath<Row, V>) -> some View {
        let current = sortBox.value.first
        let active = current?.keyPath == key as PartialKeyPath<Row>
        return Button {
            let order: SortOrder = active && current?.order == .reverse ? .forward : .reverse
            sortBox.value = [KeyPathComparator(key, order: order)]
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if active {
                    Image(systemName: current?.order == .reverse ? "chevron.down" : "chevron.up")
                        .font(.caption2.weight(.bold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(active ? .primary : .secondary)
    }
}
