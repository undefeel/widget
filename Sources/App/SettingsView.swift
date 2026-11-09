import ServiceManagement
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case agents, balance, notifications, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: return L("Агенты")
        case .balance: return L("Баланс")
        case .notifications: return L("Уведомления")
        case .general: return L("Основные")
        }
    }

    var symbol: String {
        switch self {
        case .agents: return "chart.bar.fill"
        case .balance: return "creditcard.fill"
        case .notifications: return "bell.badge.fill"
        case .general: return "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .agents: return .blue
        case .balance: return .green
        case .notifications: return .red
        case .general: return .gray
        }
    }
}

struct SettingsView: View {
    @StateObject private var paneBox = StateBox(SettingsPane.agents)

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding<SettingsPane?>(get: { paneBox.value }, set: { if let v = $0 { paneBox.value = v } })) { p in
                Label {
                    Text(p.title)
                } icon: {
                    Image(systemName: p.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.color.gradient))
                }
                .tag(p)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            switch paneBox.value {
            case .agents: AgentsPane()
            case .balance: BalancePane()
            case .notifications: NotificationsPane()
            case .general: GeneralPane()
            }
        }
        .frame(width: 720, height: 500)
    }
}

// MARK: - Агенты

private struct AgentsPane: View {
    @AppStorage("menu.claude") private var showClaude = true
    @AppStorage("menu.codex") private var showCodex = true
    @AppStorage("menu.antigravity") private var showAntigravity = true
    @AppStorage(Pref.defaultAgent) private var defaultAgent = Provider.claude.rawValue
    @AppStorage(Pref.terminal) private var terminal = Terminals.apple
    @AppStorage(Pref.hotkey) private var hotkey = true
    @StateObject private var pathsBox = StateBox<[Provider: String]?>(nil)

    var body: some View {
        Form {
            Section("В строке меню") {
                ForEach(Provider.allCases) { p in
                    Toggle(isOn: binding(p)) {
                        HStack(spacing: 10) {
                            ProviderIcon(provider: p, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.title)
                                Text(pathText(p)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Запуск") {
                Picker("Агент по умолчанию", selection: $defaultAgent) {
                    ForEach(Provider.allCases) { Text($0.agentTitle).tag($0.rawValue) }
                }
                Picker("Терминал", selection: $terminal) {
                    ForEach(Terminals.installed, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle("Сочетание ⌃⌥⌘A запускает агента по умолчанию", isOn: $hotkey)
            }
        }
        .formStyle(.grouped)
        .task {
            pathsBox.value = await Task.detached {
                Dictionary(uniqueKeysWithValues: Provider.allCases.compactMap { p in CLI.find(p.command).map { (p, $0) } })
            }.value
        }
    }

    private func binding(_ p: Provider) -> Binding<Bool> {
        switch p {
        case .claude: return $showClaude
        case .codex: return $showCodex
        case .antigravity: return $showAntigravity
        }
    }

    private func pathText(_ p: Provider) -> String {
        guard let paths = pathsBox.value else { return "…" }
        guard let path = paths[p] else { return L("\(p.command) CLI не найден") }
        return path.replacingOccurrences(of: SnapshotIO.realHome.path, with: "~")
    }
}

// MARK: - Баланс

/// Ввод API-ключа CheapVibeCode. Сохранённый ключ никогда не загружается
/// обратно в поле — панель проверяет только факт его наличия в Keychain.
private struct BalancePane: View {
    @EnvironmentObject private var store: LimitsStore
    @StateObject private var keyBox = StateBox("")
    @StateObject private var hasKeyBox = StateBox(false)

    var body: some View {
        Form {
            Section {
                SecureField("API-ключ", text: $keyBox.value)
                HStack {
                    Button("Сохранить") { save() }
                        .disabled(keyBox.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Удалить") { deleteKey() }
                    Spacer()
                    Text(hasKeyBox.value ? L("Ключ сохранён") : L("Ключ не задан"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let balance = store.snapshot.cheapVibe, balance.tokens != nil || balance.error != nil {
                Section {
                    if let tokens = balance.tokens {
                        LabeledContent(LF("Остаток: %@", Fmt.tokens(tokens))) {
                            Text(Fmt.ago(balance.updatedAt, now: store.now))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = balance.localizedError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Link("Открыть кабинет CheapVibeCode", destination: URL(string: "https://cheapvibecode.ru/portal/dashboard")!)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Хранится в macOS Keychain; в snapshot.json и логи не попадает.")
                    Text("Обновляется каждые 5 мин независимо от VPN.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            hasKeyBox.value = await Task.detached { CheapVibeKeychain.hasKey() }.value
        }
    }

    private func save() {
        let trimmed = keyBox.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        CheapVibeKeychain.save(trimmed)
        keyBox.value = ""
        hasKeyBox.value = CheapVibeKeychain.hasKey()
        store.balanceCredentialsChanged()
    }

    private func deleteKey() {
        CheapVibeKeychain.delete()
        hasKeyBox.value = CheapVibeKeychain.hasKey()
        store.balanceCredentialsChanged()
    }
}

// MARK: - Уведомления

private struct NotificationsPane: View {
    @AppStorage(Pref.notify) private var notify = true
    @AppStorage(Pref.threshold) private var threshold = 95.0
    @AppStorage(Pref.notifyReset) private var notifyReset = true
    @AppStorage(Pref.fastPoll) private var fastPoll = true

    var body: some View {
        Form {
            Section("Пороги") {
                Toggle("Предупреждать о лимитах", isOn: $notify)
                LabeledContent("Порог предупреждения") {
                    HStack {
                        Slider(value: $threshold, in: 50...100, step: 5).frame(width: 180)
                        Text("\(Int(threshold))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!notify)
                Toggle("Сообщать о сбросе лимита", isOn: $notifyReset)
                Button("Отправить тестовое уведомление") {
                    Notifier.shared.post(title: L("Проверка уведомлений"), body: L("Так будут выглядеть предупреждения о лимитах."))
                }
            }
            Section("Частота опроса") {
                LabeledContent("Claude и Antigravity", value: L("каждые 5 мин"))
                LabeledContent("Codex", value: L("каждые 2 мин"))
                LabeledContent("Статистика токенов", value: L("каждые 15 мин"))
                Toggle(isOn: $fastPoll) {
                    Text("Чаще у порога")
                    Text("Каждые 90 с, когда до порога меньше 15 пунктов")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Основные

private struct GeneralPane: View {
    @EnvironmentObject private var store: LimitsStore
    @AppStorage(LimitsStore.requireVPNKey) private var requireVPN = true
    @AppStorage(Pref.compact) private var compact = false
    @StateObject private var login = LoginItem()

    var body: some View {
        Form {
            Section {
                Toggle("Запускать при входе", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if let e = login.error { Text(e).font(.caption).foregroundStyle(.orange) }
                Toggle(isOn: Binding(get: { requireVPN }, set: { requireVPN = $0; Task { await store.refresh(force: true) } })) {
                    Text("Запрашивать лимиты только при включённом VPN")
                    Text("scutil --nc list или маршрут через utun/ipsec/ppp/wg")
                }
            }
            Section("Строка меню") {
                Toggle(isOn: $compact) {
                    Text("Компактный вид")
                    Text("Только значок, цвет по самому загруженному агенту")
                }
            }
            Section {
                LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}
