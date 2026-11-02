import SwiftUI
import ServiceManagement

// "Orelhas" pretas coladas no notch com os anéis; expande para baixo com o detalhe ao passar o mouse

private let earWidth: CGFloat = 56
private let expandedWidth: CGFloat = 380
private let windowHeight: CGFloat = 720
// metade das contas de cada lado do notch (a sobra vai pra esquerda)
private var leftAccounts: ArraySlice<Account> { accounts.prefix((accounts.count + 1) / 2) }
private var rightAccounts: ArraySlice<Account> { accounts.dropFirst((accounts.count + 1) / 2) }

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
                ear(leftAccounts).frame(width: earWidth)
                Color.clear.frame(width: model.notchSize.width)
                ear(rightAccounts).frame(width: earWidth)
            }
            .frame(height: model.notchSize.height)
            .opacity(model.expanded ? 0 : 1)

            if model.expanded {
                NotchDetailView(store: store)
                    .background(GeometryReader { geo in
                        Color.clear.onAppear { model.contentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in model.contentHeight = h }
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
                RingIcon(percent: peak, glyph: acc.glyph, tint: .white,
                         progressTint: peak.flatMap(alertColor(for:)) ?? ringGray)
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
            ForEach(accounts) { acc in
                NotchAccountRow(account: acc, usage: store.usage[acc.id])
                    .padding(.vertical, 12)
                if acc.id != accounts.last?.id {
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
            if let t = store.usage.values.compactMap(\.updatedAt).max() {
                Text("\(L("Updated", "Atualizado", "Actualizado")) \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(dim)
            }
            Spacer()
            chip(L("Login", "Login", "Inicio"), on: launchAtLogin) {
                launchAtLogin.toggle()
                try? launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            }
            chip("Notch", on: showNotch) { showNotch.toggle() }
            iconButton(store.loading ? "ellipsis" : "arrow.clockwise") { Task { await store.refresh() } }
            iconButton("power") { NSApp.terminate(nil) }
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: on ? "checkmark" : "circle.dashed").font(.system(size: 8, weight: .bold))
                Text(title)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.white.opacity(on ? 0.14 : 0.06), in: Capsule())
            .foregroundStyle(on ? .white : dim)
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 20)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
    }
}

private struct NotchAccountRow: View {
    let account: Account
    let usage: Usage?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RingIcon(percent: usage?.peak, glyph: account.glyph, tint: .white,
                     progressTint: usage?.peak.flatMap(alertColor(for:)) ?? ringGray, size: 34)

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

                if let err = usage?.error {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }

                if let windows = usage?.windows, !windows.isEmpty {
                    // colunas de largura fixa para as barras alinharem entre contas
                    VStack(spacing: 7) {
                        ForEach(windows) { w in
                            HStack(spacing: 10) {
                                Text(w.shortLabel).font(.system(size: 11)).foregroundStyle(dim)
                                    .frame(width: 46, alignment: .leading)
                                UsageBar(percent: w.percent)
                                Text("\(Int(w.percent.rounded()))%")
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .frame(width: 32, alignment: .trailing)
                                Text(resetText(w.resetsAt, short: true, countdown: w.isSession))
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

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
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
        panel.setFrame(NSRect(x: notchRect.midX - expandedWidth / 2 - 40, y: top - windowHeight,
                              width: expandedWidth + 80, height: windowHeight), display: true)
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
            let h = notchRect.height + model.contentHeight
            area = NSRect(x: notchRect.midX - expandedWidth / 2, y: notchRect.maxY - h, width: expandedWidth, height: h)
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
        if on { store.refreshIfStale() }
    }
}
