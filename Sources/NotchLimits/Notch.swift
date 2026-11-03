import SwiftUI
import ServiceManagement

// "Orelhas" pretas coladas no notch com os anéis; expande para baixo com o detalhe ao passar o mouse

private let earWidth: CGFloat = 56
private let expandedWidth = Theme.panelWidth
private let windowHeight: CGFloat = 720
// metade das contas de cada lado do notch (a sobra vai pra esquerda)
private func leftAccounts(_ list: [Account]) -> ArraySlice<Account> { list.prefix((list.count + 1) / 2) }
private func rightAccounts(_ list: [Account]) -> ArraySlice<Account> { list.dropFirst((list.count + 1) / 2) }

/// Chave do chip "Notch" (UserDefaults): ausente = mostrar o notch
let showNotchKey = "showNotch"

/// Estado compartilhado com a cena da barra (para esconder o ícone quando o notch está ativo)
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var notchVisible = false
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var notchSize = CGSize(width: 185, height: 32)
    var contentHeight: CGFloat = 0
}

struct NotchView: View {
    @ObservedObject var store: Store
    @ObservedObject var model: NotchModel
    /// Engrenagem: o controller recolhe o notch antes de abrir os Ajustes (critério 13 do R-05)
    let openSettings: () -> Void
    /// Lidos a cada expansão; os snapshots injetam os seus (D-023)
    var launchAtLogin: () -> Bool = { SMAppService.mainApp.status == .enabled }
    var defaults = UserDefaults.standard

    var body: some View {
        let collapsedWidth = model.notchSize.width + earWidth * 2
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ear(leftAccounts(store.accounts)).frame(width: earWidth)
                Color.clear.frame(width: model.notchSize.width)
                ear(rightAccounts(store.accounts)).frame(width: earWidth)
            }
            .frame(height: model.notchSize.height)
            .opacity(model.expanded ? 0 : 1)

            if model.expanded {
                NotchDetailView(store: store, openSettings: openSettings, launchAtLogin: launchAtLogin(), defaults: defaults)
                    .background(GeometryReader { geo in
                        Color.clear.onAppear { model.contentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, height in model.contentHeight = height }
                    })
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(width: model.expanded ? expandedWidth : collapsedWidth, alignment: .top)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: model.expanded ? 24 : 10,
                                   bottomTrailingRadius: model.expanded ? 24 : 10)
                .fill(Theme.ground)
                .shadow(color: .black.opacity(model.expanded ? 0.45 : 0), radius: 16, y: 8)
        )
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: model.expanded)
    }

    private func ear(_ items: ArraySlice<Account>) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(items)) { acc in
                let peak = store.usage[acc.id]?.peak
                RingIcon(
                    percent: peak,
                    glyph: acc.glyph,
                    tint: .white,
                    progressTint: peak.flatMap(alertColor(for:)) ?? Theme.ring
                )
            }
        }
    }
}

// MARK: - Detalhe expandido

struct NotchDetailView: View {
    @ObservedObject var store: Store
    let openSettings: () -> Void
    @State private var launchAtLogin: Bool
    @AppStorage private var showNotch: Bool

    /// Login e defaults entram por fora para os snapshots não lerem o sistema (D-023)
    init(store: Store,
         openSettings: @escaping () -> Void,
         launchAtLogin: Bool = SMAppService.mainApp.status == .enabled,
         defaults: UserDefaults = .standard) {
        self.store = store
        self.openSettings = openSettings
        _launchAtLogin = State(initialValue: launchAtLogin)
        _showNotch = AppStorage(wrappedValue: true, showNotchKey, store: defaults)
    }

    var body: some View {
        let best = bestAccountIDs(accounts: store.accounts, usage: store.usage, now: Date())
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.accounts) { acc in
                NotchAccountRow(account: acc, usage: store.usage[acc.id], isBest: best.contains(acc.id))
                    .padding(.vertical, 12)
                if acc.id != store.accounts.last?.id { Separator() }
            }
            footer.padding(.top, 10)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Spacer()
            Chip(tr("Login", "Login", "Inicio"), on: launchAtLogin) {
                launchAtLogin.toggle()
                setLaunchAtLogin(launchAtLogin)
            }
            Chip("Notch", on: showNotch) { showNotch.toggle() }
            IconButton("gearshape", label: tr("Settings", "Ajustes", "Ajustes"), action: openSettings)
            IconButton(store.loading ? "ellipsis" : "arrow.clockwise", label: tr("Refresh", "Atualizar", "Actualizar")) {
                Task { await store.refresh(force: true) }
            }
            IconButton("power", label: tr("Quit", "Sair", "Salir")) { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Hover

/// Quando o notch expande e recolhe. Puro (o ponteiro e o relógio entram por fora) para os testes;
/// o NotchController só mede a área e aplica o resultado
struct HoverState {
    static let openDelay: TimeInterval = 0.25    // não abre quando o mouse só passa a caminho do menu
    static let closeDelay: TimeInterval = 0.3
    private(set) var expanded = false
    private var insideSince: Date?
    private var outsideSince: Date?
    private var heldClosed = false               // recolhido ao abrir uma janela: espera o ponteiro sair

    /// Um passo do timer; inside = o ponteiro está na área atual (painel expandido, ou notch e orelhas)
    mutating func update(inside: Bool, now: Date) {
        if inside {
            outsideSince = nil
            guard !expanded, !heldClosed else { return }
            let since = insideSince ?? now
            insideSince = since
            if now.timeIntervalSince(since) > Self.openDelay { set(true) }
        } else {
            insideSince = nil
            heldClosed = false
            guard expanded else { return }
            let since = outsideSince ?? now
            outsideSince = since
            if now.timeIntervalSince(since) > Self.closeDelay { set(false) }
        }
    }

    /// Abrir uma janela recolhe na hora, para ela não ficar sob o painel; só expande de novo quando o ponteiro
    /// sair da área e voltar (D-023)
    mutating func dismiss() {
        set(false)
        heldClosed = true
    }

    /// Sem tela com notch (ou notch desligado): recolhe sem segurar
    mutating func collapse() { set(false) }

    private mutating func set(_ on: Bool) {
        expanded = on
        insideSince = nil
        outsideSince = nil
    }
}

// MARK: - Janela

@MainActor
final class NotchController {
    private let model = NotchModel()
    private let panel: NSPanel
    private var notchRect: NSRect = .zero        // área do notch em coordenadas de tela
    private var hover = HoverState()
    private let store: Store

    init(store: Store) {
        self.store = store
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: NotchView(store: store, model: model) { [weak self] in self?.openSettings() })
        host.sizingOptions = []
        panel.contentView = host

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        layout()
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: showNotchKey) as? Bool ?? true }

    /// Posiciona no monitor com notch; some se não houver nenhum (ex.: tampa fechada + monitor externo)
    private func layout() {
        guard Self.enabled,
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else {
            hover.collapse()
            apply()
            panel.orderOut(nil)
            AppState.shared.notchVisible = false
            return
        }

        let top = screen.frame.maxY
        let height = screen.safeAreaInsets.top
        notchRect = NSRect(x: left.maxX, y: top - height, width: right.minX - left.maxX, height: height)
        model.notchSize = notchRect.size
        let frame = NSRect(
            x: notchRect.midX - expandedWidth / 2 - 40,
            y: top - windowHeight,
            width: expandedWidth + 80,
            height: windowHeight
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        AppState.shared.notchVisible = true
    }

    private func tick() {
        if Self.enabled != panel.isVisible { layout() }
        guard panel.isVisible else { return }

        let area: NSRect
        if hover.expanded {
            let height = notchRect.height + model.contentHeight
            area = NSRect(x: notchRect.midX - expandedWidth / 2, y: notchRect.maxY - height, width: expandedWidth, height: height)
        } else {
            area = notchRect.insetBy(dx: -earWidth, dy: 0)
        }

        let wasExpanded = hover.expanded
        hover.update(inside: area.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation), now: Date())
        if hover.expanded != wasExpanded { apply() }
    }

    /// Engrenagem: recolhe antes de abrir, senão o painel (acima do menu) cobre a janela dos Ajustes
    private func openSettings() {
        hover.dismiss()
        apply()
        SettingsWindow.shared.show(store: store)
    }

    private func apply() {
        model.expanded = hover.expanded
        panel.ignoresMouseEvents = !hover.expanded
        if hover.expanded { Task { await store.refresh(network: false) } }   // abrir não faz requisição
    }
}
