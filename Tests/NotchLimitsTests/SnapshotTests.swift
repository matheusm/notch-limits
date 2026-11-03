import AppKit
import SwiftUI
import Testing
import UserNotifications
@testable import NotchLimits

// Renderiza cada superfície do app em PNG, fora da tela, com dados de exemplo, para agentes verem a UI sem gravar a tela.
// É uma ferramenta, não um gate: sem SNAPSHOT_DIR a suíte não roda (D-023).
// SNAPSHOT_DIR=.evidence/snapshots/<item> swift test --filter Snapshots

private let snapshotDir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]

@MainActor
@Suite("Snapshots", .enabled(if: snapshotDir != nil), .serialized)
struct Snapshots {
    let now = Date()
    /// Defaults vazios e só para leitura: nenhum snapshot lê nem grava o UserDefaults real
    let defaults = UserDefaults(suiteName: "notch-limits-snapshots-\(UUID().uuidString)")!

    @Test func notchPanel() throws {
        let store = fixtureStore()
        let model = NotchModel()
        model.expanded = true
        let panel = NotchView(store: store, model: model, openSettings: {}, launchAtLogin: { true }, defaults: defaults)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 28)   // espaço para a sombra do painel
        try Snapshot.render(panel, backdrop: true, appearance: nil, name: "notch-panel")
    }

    /// Sem forçar a aparência: o que o MenuBarExtra mostra com a aparência atual do sistema
    @Test func menuBarPanel() throws {
        let view = ContentView(store: fixtureStore(), launchAtLogin: true, defaults: defaults)
        try Snapshot.render(view, backdrop: false, appearance: nil, name: "menu-bar-panel")
    }

    /// Sistema no modo claro: o painel tem de continuar preto
    @Test func menuBarPanelInLightMode() throws {
        let view = ContentView(store: fixtureStore(), launchAtLogin: true, defaults: defaults)
            .environment(\.colorScheme, .light)
        try Snapshot.render(view, backdrop: false, appearance: .aqua, name: "menu-bar-panel-light")
    }

    @Test func settingsWithNotificationsOff() throws {
        let home = settingsHome()
        let settings = AccountSettings(file: home.file, home: home.dir.path) { _ in }
        settings.reload()
        settings.setEnabled(false, id: settings.list[1].id)
        try renderSettings(settings, notifications: notifications(on: false), name: "settings-notifications-off")
    }

    @Test func settingsWithNotificationsOn() async throws {
        let home = settingsHome()
        let settings = AccountSettings(file: home.file, home: home.dir.path) { _ in }
        settings.reload()
        settings.setEnabled(false, id: settings.list[1].id)
        let on = notifications(on: true)
        await on.reload()
        try renderSettings(settings, notifications: on, name: "settings-notifications-on")
    }

    /// Notificações desligadas no sistema: a legenda que manda para os Ajustes do Sistema
    @Test func settingsWithNotificationsDenied() async throws {
        let home = settingsHome()
        let settings = AccountSettings(file: home.file, home: home.dir.path) { _ in }
        settings.reload()
        let denied = notifications(on: true, status: .denied)
        await denied.reload()
        try renderSettings(settings, notifications: denied, name: "settings-notifications-denied")
    }

    /// A última conta visível: o chip fica apagado e não clica
    @Test func settingsWithTheLastShownAccount() throws {
        let home = settingsHome()
        let settings = AccountSettings(file: home.file, home: home.dir.path) { _ in }
        settings.reload()
        settings.setEnabled(false, id: settings.list[0].id)
        settings.setEnabled(false, id: settings.list[1].id)
        #expect(settings.isLastShown(settings.list[2].id))
        try renderSettings(settings, notifications: notifications(on: false), name: "settings-last-shown")
    }

    /// Mais alto que a tela: a janela para na altura máxima e a lista rola
    @Test func settingsTallerThanTheScreen() throws {
        let home = settingsHome()
        let settings = AccountSettings(file: home.file, home: home.dir.path) { _ in }
        settings.reload()
        let view = SettingsView(model: settings, notifications: notifications(on: false), maxHeight: 220)
        try Snapshot.render(window: SettingsWindow.makeWindow(view), name: "settings-scrolls")
    }

    @Test func settingsWithASaveError() throws {
        let home = settingsHome()
        home.dir.write(".config", "a file where the folder should be")
        let settings = AccountSettings(file: home.file, home: home.dir.path) { _ in }
        settings.reload()
        settings.setEnabled(false, id: settings.list[1].id)
        #expect(settings.saveError != nil)
        try renderSettings(settings, notifications: notifications(on: false), name: "settings-save-error")
    }
}

// MARK: - Dados de exemplo

extension Snapshots {
    /// Três contas: "Melhor agora" na primeira, ritmo e janela acima de 70% na segunda, ritmo neutro na semana do Codex
    func fixtureStore() -> Store {
        let claude = Account(name: "Claude", glyph: .claude, provider: .claude(configDir: "/Users/me/.claude"))
        let work = Account(
            name: "Claude Work",
            glyph: .symbol("leaf.fill"),
            provider: .claude(configDir: "/Users/me/.claude-work")
        )
        let codex = Account(name: "Codex", glyph: .codex, provider: .codex(home: "/Users/me/.codex"))
        let store = Store(accounts: [claude, work, codex], local: { _ in nil }, remote: { _ in Usage() }, autoRefresh: false)
        let updated = now.addingTimeInterval(-120)
        let hour: TimeInterval = 3600
        store.usage = [
            claude.id: Usage(
                windows: [window(.session(hours: 5), 18, resetsAt: now + 3.5 * hour), window(.weekly, 31, resetsAt: now + 80 * hour)],
                plan: "max",
                updatedAt: updated
            ),
            // sessão em 80% com 3 h de 5 h passadas: o ritmo chega a 100% antes do reset
            work.id: Usage(
                windows: [window(.session(hours: 5), 80, resetsAt: now + 2 * hour), window(.weekly, 46, resetsAt: now + 50 * hour)],
                plan: "pro",
                updatedAt: updated
            ),
            codex.id: Usage(
                windows: [window(.session(hours: 5), 12, resetsAt: now + 4 * hour), window(.weekly, 30, resetsAt: now + 120 * hour)],
                plan: "plus",
                updatedAt: updated
            ),
        ]
        return store
    }

    /// Home falsa com Claude, Claude Work e Codex; nada sai da pasta temporária
    func settingsHome() -> (dir: TempDir, file: String) {
        let dir = TempDir(files: [".claude.json", ".claude-work/.claude.json", ".codex/auth.json"])
        return (dir, "\(dir.path)/.config/notch-limits/accounts.json")
    }

    func notifications(on: Bool, status: UNAuthorizationStatus = .authorized) -> NotificationSettings {
        NotificationSettings(isOn: on, save: { _ in }, requestPermission: { true }, authorization: { status })
    }

    func renderSettings(_ settings: AccountSettings, notifications: NotificationSettings, name: String) throws {
        let window = SettingsWindow.makeWindow(SettingsView(model: settings, notifications: notifications))
        try Snapshot.render(window: window, name: name)
    }
}

// MARK: - Renderização

/// NSHostingView numa janela fora da tela + cacheDisplay: o ImageRenderer não desenha controles do AppKit
@MainActor
enum Snapshot {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// appearance nil não força nada (vale a do sistema). O fundo da janela é o do sistema, como o material do
    /// MenuBarExtra: uma superfície que não pinta o próprio preto aparece clara no modo claro
    static func render(_ view: some View, backdrop: Bool, appearance: NSAppearance.Name?, name: String) throws {
        _ = NSApplication.shared
        let scheme: ColorScheme? = appearance.map { $0 == .aqua ? .light : .dark }
        let root = view
            .background(backdrop ? Color(white: 0.24) : .clear)
            .transformEnvironment(\.colorScheme) { if let scheme { $0 = scheme } }
        let host = NSHostingView(rootView: root)
        host.appearance = appearance.flatMap(NSAppearance.init(named:))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        try capture(host, name: name)
    }

    /// A janela inteira, com a barra de título, como o app a mostra; a aparência é a que a janela do app define
    static func render(window: NSWindow, name: String) throws {
        _ = NSApplication.shared
        guard let frameView = window.contentView?.superview else { throw Failure(description: "window has no frame view") }
        window.contentView?.layoutSubtreeIfNeeded()
        try capture(frameView, name: name)
    }

    /// Sempre 2x e sRGB: a escala e o perfil de cor da janela fora da tela dependem do monitor onde ela cai
    /// (um externo dá 1x), e assim o PNG sai igual em qualquer Mac
    private static func capture(_ view: NSView, name: String) throws {
        guard let snapshotDir else { return }
        settle()
        view.layoutSubtreeIfNeeded()
        view.display()
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )?.retagging(with: .sRGB) else {
            throw Failure(description: "no bitmap for \(name)")
        }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no PNG for \(name)") }
        let dir = URL(fileURLWithPath: snapshotDir, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// Deixa o SwiftUI aplicar onAppear e mudanças de estado antes de desenhar
    private static func settle() {
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }
}
