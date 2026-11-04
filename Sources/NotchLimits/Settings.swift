import SwiftUI
import UserNotifications

// Ajustes: todas as contas, encontradas ou configuradas, com mostrar/esconder, ícone, nome e ordem.
// Cada mudança confirmada grava o accounts.json e vale na hora, sem botão de salvar

/// Lista editada nos Ajustes; grava e aplica a cada mudança confirmada
@MainActor
final class AccountSettings: ObservableObject {
    @Published private(set) var list: [Account] = []
    @Published private(set) var saveError: String?
    let home: String
    private let file: String
    private let apply: ([Account]) -> Void

    /// apply recebe a lista completa (o Store fica só com as visíveis)
    init(file: String = configFile, home: String = NotchLimits.home, apply: @escaping ([Account]) -> Void) {
        self.file = file
        self.home = home
        self.apply = apply
    }

    /// Ao abrir: relê o accounts.json e a home e aplica, sem gravar (abrir não muda um arquivo feito à mão).
    /// A lista volta ao que está no disco, então o erro de uma gravação anterior não vale mais
    func reload() {
        list = loadAccounts(from: file, home: home)
        saveError = nil
        apply(list)
    }

    /// A última conta visível não pode ser escondida
    func isLastShown(_ id: String) -> Bool {
        list.filter(\.enabled).map(\.id) == [id]
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard enabled || !isLastShown(id) else { return }
        change(id) { $0.enabled = enabled }
    }

    /// Nome vazio mantém o anterior
    func rename(_ name: String, id: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, list.first(where: { $0.id == id })?.name != name else { return }
        change(id) { $0.name = name }
    }

    func setIcon(_ icon: String, id: String) {
        change(id) { $0.glyph = Glyph(name: icon) }
    }

    func move(id: String, by offset: Int) {
        guard let index = list.firstIndex(where: { $0.id == id }), list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        commit()
    }

    private func change(_ id: String, _ edit: (inout Account) -> Void) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        edit(&list[index])
        commit()
    }

    /// Se a gravação falhar, a mudança continua aplicada e o erro aparece na janela
    private func commit() {
        do {
            try saveAccounts(list, to: file, home: home)
            saveError = nil
        } catch {
            let reason = error.localizedDescription
            saveError = tr(
                "Couldn't save accounts.json: \(reason)",
                "Não foi possível salvar o accounts.json: \(reason)",
                "No se pudo guardar accounts.json: \(reason)"
            )
        }
        apply(list)
    }
}

/// Toggle das notificações: a permissão só é pedida quando o usuário liga, nunca no launch nem num refresh
@MainActor
final class NotificationSettings: ObservableObject {
    @Published private(set) var isOn: Bool          // o que o toggle mostra (ligado também com o pedido na tela)
    @Published private(set) var denied = false      // mostra a legenda que manda para os Ajustes do Sistema
    private var saved: Bool                         // o que está gravado: um pedido em aberto ainda não conta
    private var changes = 0                         // toques no toggle, para descartar respostas atrasadas
    private let save: (Bool) -> Void
    private let requestPermission: () async -> Bool
    private let authorization: () async -> UNAuthorizationStatus

    init(isOn: Bool = UserDefaults.standard.bool(forKey: notifyLimitsKey),
         save: @escaping (Bool) -> Void = { UserDefaults.standard.set($0, forKey: notifyLimitsKey) },
         requestPermission: @escaping () async -> Bool = { await SystemNotifications.shared.requestPermission() },
         authorization: @escaping () async -> UNAuthorizationStatus = { await SystemNotifications.shared.authorization() }) {
        self.isOn = isOn
        self.saved = isOn
        self.save = save
        self.requestPermission = requestPermission
        self.authorization = authorization
    }

    /// Negado ou com erro, o toggle volta a desligado e a legenda aparece
    func setOn(_ on: Bool) async {
        changes += 1
        let change = changes
        isOn = on                                   // fica ligado enquanto o pedido do macOS está na tela
        denied = false
        guard on else {
            store(false)
            return
        }
        let granted = await requestPermission()
        guard change == changes else { return }     // mexeram no toggle com o pedido na tela: vale o toque mais novo
        isOn = granted
        denied = !granted
        store(granted)
    }

    /// Ao abrir os Ajustes mostra o estado real, sem pedir de novo: negado no sistema mostra a legenda; permissão
    /// nunca respondida (ex.: zerada com tccutil) desliga, pois nada seria entregue, e ligar de novo volta a pedir
    func reload() async {
        guard saved else {
            denied = false
            return
        }
        let change = changes
        let status = await authorization()
        guard change == changes else { return }     // um toque durante a consulta vence
        denied = status == .denied
        if status == .notDetermined {
            isOn = false
            store(false)
        }
    }

    private func store(_ on: Bool) {
        saved = on
        save(on)
    }
}

/// Janela do AppKit: o painel do notch é um NSHostingView fora das cenas do SwiftUI, onde openWindow e SettingsLink falham
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var model: AccountSettings?
    private var notifications: NotificationSettings?

    /// Cada clique na engrenagem relê o accounts.json e a home, mesmo com a janela aberta, e traz a mesma janela para a frente.
    /// Um nome sendo digitado não se perde: a linha só troca o rascunho quando o nome salvo daquela conta muda
    func show(store: Store) {
        let window = window ?? makeWindow(store: store)
        let opening = !window.isVisible
        model?.reload()
        if let notifications { Task { await notifications.reload() } }
        NSApp.activate(ignoringOtherApps: true)    // app LSUIElement: sem isso a janela abre atrás das outras
        window.makeKeyAndOrderFront(nil)
        // ao abrir, nenhum nome fica em edição; com a janela já aberta o foco fica onde está, para não perder um rascunho
        if opening { window.makeFirstResponder(nil) }
    }

    private func makeWindow(store: Store) -> NSWindow {
        let model = AccountSettings { list in store.setAccounts(list) }
        let notifications = NotificationSettings()
        // a lista rola só se passar da tela; desconta a barra de título e uma folga
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        let window = Self.makeWindow(SettingsView(model: model, notifications: notifications, maxHeight: maxHeight))
        window.center()
        self.model = model
        self.notifications = notifications
        self.window = window
        return window
    }

    /// A mesma janela que o app abre; os snapshots renderizam esta.
    /// Preta como o painel: barra de título transparente sobre o fundo preto e sem título (os botões de janela ficam,
    /// Cmd+W fecha); o tamanho segue o conteúdo, sem redimensionar. Sem fullSizeContentView: o conteúdo já fica abaixo
    /// dos botões, e com ele o cacheDisplay dos snapshots não desenha o SwiftUI
    static func makeWindow(_ view: SettingsView) -> NSWindow {
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = tr("Notch Limits Settings", "Ajustes do Notch Limits", "Ajustes de Notch Limits")   // VoiceOver, Mission Control
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(host.view.fittingSize)   // nasce 1×0; sem isso o center() centraliza um ponto
        return window
    }
}
