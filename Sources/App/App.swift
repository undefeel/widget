import AppKit
import Combine
import SwiftUI

@main
enum Main {
    private static var delegate: AppDelegate!

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// Значок в строке меню (NSStatusItem): левый клик — панель агентов, правый — меню запуска.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: LimitsStore!
    private let panel = PanelState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private let hotKey = HotKey()
    private var bag = Set<AnyCancellable>()
    private var lastMenuBarRenderKey: MenuBarRenderKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = LimitsStore()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let host = NSHostingController(rootView: PopoverView().environmentObject(store).environmentObject(panel))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        panel.openSettings = { [weak self] in self?.showSettings() }

        store.$snapshot.combineLatest(store.$now)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.syncHotKey() }
            .store(in: &bag)

        HotKey.handler = { [weak self] in self?.panel.launch(Pref.defaultProvider) }
        syncHotKey()
        Notifier.shared.requestAuthorization()
        updateIcon()
    }

    // MARK: Значок

    private func updateIcon() {
        guard let b = statusItem?.button else { return }
        let dark = b.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let snapshot = store.snapshot
        let visible = Pref.visibleProviders
        let compact = UserDefaults.standard.bool(forKey: Pref.compact)
        let shown = visible.isEmpty ? Provider.allCases : visible
        let key = MenuBarRenderKey(paused: snapshot.paused != nil, visible: visible,
                                   compact: compact, dark: dark,
                                   headlines: shown.map { snapshot.status($0).headline(at: store.now) })
        guard key != lastMenuBarRenderKey else { return }
        // Record before rendering so reentrant snapshot notifications cannot
        // trigger duplicate image work for the same visible state.
        lastMenuBarRenderKey = key
        b.image = MenuBarRenderer.image(snapshot: snapshot, now: store.now, visible: visible,
                                        compact: compact, dark: dark)
    }

    private func syncHotKey() {
        let on = UserDefaults.standard.bool(forKey: Pref.hotkey)
        if on != hotKey.isRegistered { on ? hotKey.register() : hotKey.unregister() }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover(page: .main)
        }
    }

    private func togglePopover(page: PanelState.Page) {
        if popover.isShown, panel.page == page { popover.performClose(nil); return }
        panel.page = page
        guard let b = statusItem.button else { return }
        if !popover.isShown { popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Меню по правому клику

    private func showMenu() {
        let menu = NSMenu()
        let def = Pref.defaultProvider
        for p in [def] + Provider.allCases.filter({ $0 != def }) {
            let item = NSMenuItem(title: LF("Запустить %@", p.agentTitle), action: #selector(launchItem(_:)), keyEquivalent: "")
            if p == def, hotKey.isRegistered {
                item.keyEquivalent = "a"
                item.keyEquivalentModifierMask = [.control, .option, .command]
            }
            item.representedObject = p.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(item(L("Обновить"), #selector(refreshNow), "r"))
        menu.addItem(item(L("Статистика токенов…"), #selector(showStats), ""))
        menu.addItem(item(L("Настройки…"), #selector(showSettingsAction), ","))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func launchItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = Provider(rawValue: raw) else { return }
        panel.launch(p)
    }

    @objc private func refreshNow() { Task { await store.refresh(force: true) } }
    @objc private func showStats() { togglePopover(page: .stats) }
    @objc private func showSettingsAction() { showSettings() }

    // MARK: Настройки

    func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(store))
            let w = NSWindow(contentViewController: host)
            w.title = L("Настройки AILimits")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct MenuBarRenderKey: Equatable {
    let paused: Bool
    let visible: [Provider]
    let compact: Bool
    let dark: Bool
    let headlines: [Double?]
}

/// Состояние панели: какая страница открыта и что показать в подвале.
@MainActor
final class PanelState: ObservableObject {
    enum Page { case main, stats }

    @Published var page: Page = .main
    @Published var status: String?
    var openSettings: () -> Void = {}

    func launch(_ p: Provider) {
        status = LF("Открываю %@…", p.command)
        Task.detached {
            let error = Launcher.launch(p)
            await MainActor.run {
                self.status = error
                if let error { Notifier.shared.post(title: p.agentTitle, body: error) }
            }
            if error == nil { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run { if self.status == error { self.status = nil } }
        }
    }
}

// MARK: - Menu bar label

private struct MenuBarLabel: View {
    let snapshot: Snapshot
    let now: Date
    let visible: [Provider]
    let compact: Bool
    /// nil — шаблонная картинка (цвет подставит система).
    let base: Color?

    var body: some View {
        HStack(spacing: 7) {
            if snapshot.paused != nil {
                Image(systemName: "shield.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(base == nil ? Color.black : Color.orange)
            }
            if compact || visible.isEmpty {
                let worst = (visible.isEmpty ? Provider.allCases : visible)
                    .compactMap { snapshot.status($0).headline(at: now) }.max()
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color(worst))
            } else {
                ForEach(visible) { p in
                    let h = snapshot.status(p).headline(at: now)
                    HStack(spacing: 3) {
                        ProviderGlyph(provider: p, size: 14)
                        Text(Fmt.percent(h))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(color(h))
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func color(_ used: Double?) -> Color {
        guard let base else { return .black }
        guard let used else { return base }
        return used >= 90 ? .red : (used >= 70 ? .orange : base)
    }
}

@MainActor
enum MenuBarRenderer {
    /// Пока всё спокойно — шаблонная картинка; при ≥ 70% — цветная, под тему строки меню.
    static func image(snapshot: Snapshot, now: Date, visible: [Provider], compact: Bool, dark: Bool) -> NSImage {
        let shown = visible.isEmpty ? Provider.allCases : visible
        let warn = shown.contains { (snapshot.status($0).headline(at: now) ?? 0) >= 70 }
        let label = MenuBarLabel(snapshot: snapshot, now: now, visible: visible, compact: compact,
                                 base: warn ? (dark ? .white : .black) : nil)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: label)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = renderer.nsImage ?? NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)!
        img.isTemplate = !warn
        return img
    }
}
