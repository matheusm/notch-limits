import SwiftUI
import UserNotifications

// Ajustes: todas as contas, encontradas ou configuradas, com mostrar/esconder, ícone, nome e ordem.
// Cada mudança confirmada grava o accounts.json e vale na hora, sem botão de salvar (D-014)

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

/// Toggle das notificações (R-06): a permissão só é pedida quando o usuário liga, nunca no launch nem num refresh
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

struct SettingsView: View {
    @ObservedObject var model: AccountSettings
    @ObservedObject var notifications: NotificationSettings

    var body: some View {
        Form {
            Section {
                ForEach(model.list) { account in
                    AccountSettingsRow(
                        account: account,
                        model: model,
                        isFirst: account.id == model.list.first?.id,
                        isLast: account.id == model.list.last?.id
                    )
                }
            } header: {
                Text(tr("Accounts", "Contas", "Cuentas"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = model.saveError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(tr(
                        "Accounts in ~/.claude* and ~/.codex* are found automatically. Changes are saved to "
                            + "~/.config/notch-limits/accounts.json; add folders kept elsewhere there by hand.",
                        "Contas em ~/.claude* e ~/.codex* são encontradas automaticamente. As mudanças são salvas em "
                            + "~/.config/notch-limits/accounts.json; adicione lá, à mão, pastas que ficam em outro lugar.",
                        "Las cuentas en ~/.claude* y ~/.codex* se detectan automáticamente. Los cambios se guardan en "
                            + "~/.config/notch-limits/accounts.json; agrega allí a mano las carpetas que estén en otro lugar."
                    ))
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            notificationsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 300)
    }
}

extension SettingsView {
    private var notificationsSection: some View {
        Section {
            Toggle(
                tr(
                    "Notify at 90% and when a limit resets",
                    "Avisar em 90% e quando um limite resetar",
                    "Avisar al 90% y cuando un límite se reinicie"
                ),
                isOn: Binding(get: { notifications.isOn }, set: { on in Task { await notifications.setOn(on) } })
            )
        } header: {
            Text(tr("Notifications", "Notificações", "Notificaciones"))
        } footer: {
            if notifications.denied {
                Text(tr(
                    "Notifications for Notch Limits are off in System Settings → Notifications.",
                    "As notificações do Notch Limits estão desativadas em Ajustes do Sistema → Notificações.",
                    "Las notificaciones de Notch Limits están desactivadas en Ajustes del Sistema → Notificaciones."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AccountSettingsRow: View {
    let account: Account
    @ObservedObject var model: AccountSettings
    let isFirst: Bool
    let isLast: Bool
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { account.enabled }, set: { model.setEnabled($0, id: account.id) })) {
                Text(tr("Show \(account.name)", "Mostrar \(account.name)", "Mostrar \(account.name)"))
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(model.isLastShown(account.id))

            RingIcon(percent: 0, glyph: account.glyph, tint: .primary, size: 18)
                .accessibilityHidden(true)   // decorativo: o menu ao lado diz qual é o ícone
            iconMenu

            VStack(alignment: .leading, spacing: 2) {
                TextField(tr("Name", "Nome", "Nombre"), text: $draft, prompt: Text(tr("Name", "Nome", "Nombre")))
                    .labelsHidden()
                    .focused($editing)
                    .onSubmit(commitName)
                    .onChange(of: editing) { _, focused in if !focused { commitName() } }
                    .onChange(of: account.name) { _, name in draft = name }
                    .onAppear { draft = account.name }
                Text("\(account.provider.title) · \(abbreviate(account.provider.path, home: model.home))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 240)

            Spacer(minLength: 0)
            moveButton("chevron.up", label: tr("Move up", "Mover para cima", "Subir"), offset: -1).disabled(isFirst)
            moveButton("chevron.down", label: tr("Move down", "Mover para baixo", "Bajar"), offset: 1).disabled(isLast)
        }
    }

    private var iconMenu: some View {
        let known = ["claude", "codex"] + extraIcons.map(\.symbol)
        return Picker(selection: Binding(get: { account.glyph.name }, set: { model.setIcon($0, id: account.id) })) {
            Text("Claude").tag("claude")
            Text("Codex").tag("codex")
            ForEach(extraIcons, id: \.symbol) { icon in
                Label(icon.label, systemImage: icon.symbol).tag(icon.symbol)
            }
            // ícone próprio vindo do arquivo: aparece com o nome cru do símbolo
            if !known.contains(account.glyph.name) {
                Text(account.glyph.name).tag(account.glyph.name)
            }
        } label: {
            Text(tr("Icon", "Ícone", "Icono"))
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Volta ao nome salvo quando o campo fica vazio
    private func commitName() {
        model.rename(draft, id: account.id)
        draft = model.list.first { $0.id == account.id }?.name ?? draft
    }

    private func moveButton(_ symbol: String, label: String, offset: Int) -> some View {
        Button {
            model.move(id: account.id, by: offset)
        } label: {
            Image(systemName: symbol).accessibilityLabel(label)
        }
        .buttonStyle(.borderless)
        .help(label)
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
        model?.reload()
        if let notifications { Task { await notifications.reload() } }
        NSApp.activate(ignoringOtherApps: true)    // app LSUIElement: sem isso a janela abre atrás das outras
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(store: Store) -> NSWindow {
        let model = AccountSettings { list in store.setAccounts(list) }
        let notifications = NotificationSettings()
        let view = SettingsView(model: model, notifications: notifications)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = tr("Notch Limits Settings", "Ajustes do Notch Limits", "Ajustes de Notch Limits")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 500, height: 300)
        window.setContentSize(NSSize(width: 540, height: 420))
        window.center()
        self.model = model
        self.notifications = notifications
        self.window = window
        return window
    }
}
