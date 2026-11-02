import SwiftUI
import ServiceManagement

// "Orelhas" pretas coladas no notch com os anéis; expande para baixo com o detalhe ao passar o mouse

private let earWidth: CGFloat = 56
private let expandedWidth: CGFloat = 380
private let windowHeight: CGFloat = 720
// metade das contas de cada lado do notch (a sobra vai pra esquerda)
private func leftAccounts(_ list: [Account]) -> ArraySlice<Account> { list.prefix((list.count + 1) / 2) }
private func rightAccounts(_ list: [Account]) -> ArraySlice<Account> { list.dropFirst((list.count + 1) / 2) }

private let ringGray = Color(white: 0.82)
private let dim = Color.white.opacity(0.45)

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
                NotchDetailView(store: store)
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
                .fill(.black)
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
                    progressTint: peak.flatMap(alertColor(for:)) ?? ringGray
                )
            }
        }
    }
}

// MARK: - Detalhe expandido

private struct NotchDetailView: View {
    @ObservedObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("showNotch") private var showNotch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.accounts) { acc in
                NotchAccountRow(account: acc, usage: store.usage[acc.id])
                    .padding(.vertical, 12)
                if acc.id != store.accounts.last?.id {
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
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
            chip(tr("Login", "Login", "Inicio"), on: launchAtLogin) {
                launchAtLogin.toggle()
                setLaunchAtLogin(launchAtLogin)
            }
            chip("Notch", on: showNotch) { showNotch.toggle() }
            iconButton("gearshape", label: tr("Settings", "Ajustes", "Ajustes")) { SettingsWindow.shared.show(store: store) }
            iconButton(store.loading ? "ellipsis" : "arrow.clockwise", label: tr("Refresh", "Atualizar", "Actualizar")) {
                Task { await store.refresh(force: true) }
            }
            iconButton("power", label: tr("Quit", "Sair", "Salir")) { NSApp.terminate(nil) }
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: on ? "checkmark" : "circle.dashed")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)   // o estado vai no traço de botão selecionado
                Text(title)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.white.opacity(on ? 0.14 : 0.06), in: Capsule())
            .foregroundStyle(on ? .white : dim)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .accessibilityLabel(label)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 20)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .help(label)
    }
}

private struct NotchAccountRow: View {
    let account: Account
    let usage: Usage?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RingIcon(
                percent: usage?.peak,
                glyph: account.glyph,
                tint: .white,
                progressTint: usage?.peak.flatMap(alertColor(for:)) ?? ringGray,
                size: 34
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(account.name).font(.system(size: 13, weight: .semibold))
                    if let plan = usage?.plan, !plan.isEmpty {
                        Text(plan.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.5)
                            .foregroundStyle(dim)
                    }
                    Spacer()
                    if let peak = usage?.peak {
                        Text("\(Int(peak.rounded()))%")
                            .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(alertColor(for: peak) ?? .white)
                    }
                }

                if let at = usage?.updatedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(ageText(at)).font(.system(size: 10))
                            .foregroundStyle(usage?.isStale == true ? .orange : dim)
                    }
                    .padding(.top, -4)
                }

                if let err = usage?.visibleError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }

                if let windows = usage?.windows, !windows.isEmpty {
                    // colunas de largura fixa para as barras alinharem entre contas
                    VStack(spacing: 7) {
                        ForEach(windows) { limit in
                            HStack(spacing: 10) {
                                Text(limit.shortLabel).font(.system(size: 11)).foregroundStyle(dim)
                                    .frame(width: 46, alignment: .leading)
                                UsageBar(percent: limit.percent)
                                Text("\(Int(limit.percent.rounded()))%")
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .frame(width: 32, alignment: .trailing)
                                Text(resetText(limit.resetsAt, short: true, countdown: limit.isSession))
                                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(dim)
                                    .frame(width: 96, alignment: .trailing)
                            }
                        }
                    }
                } else if usage == nil {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

private struct UsageBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(alertColor(for: percent) ?? ringGray)
                    .frame(width: max(geo.size.width * min(percent, 100) / 100, percent > 0 ? 4 : 0))
            }
        }
        .frame(height: 4)
        .frame(minWidth: 80, maxWidth: .infinity)
    }
}

// MARK: - Janela

@MainActor
final class NotchController {
    private let model = NotchModel()
    private let panel: NSPanel
    private var notchRect: NSRect = .zero        // área do notch em coordenadas de tela
    private var insideSince: Date?
    private var outsideSince: Date?
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
        let host = NSHostingView(rootView: NotchView(store: store, model: model))
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

    static var enabled: Bool { UserDefaults.standard.object(forKey: "showNotch") as? Bool ?? true }

    /// Posiciona no monitor com notch; some se não houver nenhum (ex.: tampa fechada + monitor externo)
    private func layout() {
        guard Self.enabled,
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else {
            setExpanded(false)
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

        let mouse = NSEvent.mouseLocation
        let now = Date()
        let area: NSRect
        if model.expanded {
            let height = notchRect.height + model.contentHeight
            area = NSRect(x: notchRect.midX - expandedWidth / 2, y: notchRect.maxY - height, width: expandedWidth, height: height)
        } else {
            area = notchRect.insetBy(dx: -earWidth, dy: 0)
        }

        if area.insetBy(dx: -2, dy: -2).contains(mouse) {
            outsideSince = nil
            // pequeno atraso para não abrir quando o mouse só passa a caminho do menu
            if !model.expanded, now.timeIntervalSince(insideSince ?? { insideSince = now; return now }()) > 0.25 {
                setExpanded(true)
            }
        } else {
            insideSince = nil
            if model.expanded, now.timeIntervalSince(outsideSince ?? { outsideSince = now; return now }()) > 0.3 {
                setExpanded(false)
            }
        }
    }

    private func setExpanded(_ on: Bool) {
        model.expanded = on
        panel.ignoresMouseEvents = !on
        insideSince = nil
        outsideSince = nil
        if on { Task { await store.refresh(network: false) } }   // abrir não faz requisição
    }
}
