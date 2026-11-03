import SwiftUI

// Ajustes no visual do painel do notch (D-023): fundo preto, chips, botões de ícone, separadores e texto apagado,
// todos de Theme.swift. Nada de Form, switch, picker ou campo com borda

struct SettingsView: View {
    @ObservedObject var model: AccountSettings
    @ObservedObject var notifications: NotificationSettings
    /// Acima disso a lista rola; SettingsWindow passa a altura da tela, lida na borda
    var maxHeight: CGFloat = 720

    var body: some View {
        // a janela acompanha a altura do conteúdo e só rola quando ele passa da tela
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Theme.panelWidth)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.ground)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Settings", "Ajustes", "Ajustes")).font(Theme.title)
                .accessibilityAddTraits(.isHeader)
            Tag(tr("Accounts", "Contas", "Cuentas")).padding(.top, 16)
            ForEach(model.list) { account in
                AccountSettingsRow(
                    account: account,
                    model: model,
                    isFirst: account.id == model.list.first?.id,
                    isLast: account.id == model.list.last?.id
                )
                .padding(.vertical, 10)
                if account.id != model.list.last?.id { Separator() }
            }
            if let error = model.saveError {
                WarningLine(error).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            notificationsSection.padding(.top, 20)
            Text(tr(
                "Accounts in ~/.claude* and ~/.codex* are found automatically. Changes are saved to "
                    + "~/.config/notch-limits/accounts.json; add folders kept elsewhere there by hand.",
                "Contas em ~/.claude* e ~/.codex* são encontradas automaticamente. As mudanças são salvas em "
                    + "~/.config/notch-limits/accounts.json; adicione lá, à mão, pastas que ficam em outro lugar.",
                "Las cuentas en ~/.claude* y ~/.codex* se detectan automáticamente. Los cambios se guardan en "
                    + "~/.config/notch-limits/accounts.json; agrega allí a mano las carpetas que estén en otro lugar."
            ))
            .secondaryText()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Tag(tr("Notifications", "Notificações", "Notificaciones"))
            Chip(
                tr(
                    "Notify at 90% and when a limit resets",
                    "Avisar em 90% e quando um limite resetar",
                    "Avisar al 90% y cuando un límite se reinicie"
                ),
                on: notifications.isOn
            ) {
                let on = !notifications.isOn
                Task { await notifications.setOn(on) }
            }
            if notifications.denied {
                Text(tr(
                    "Notifications for Notch Limits are off in System Settings → Notifications.",
                    "As notificações do Notch Limits estão desativadas em Ajustes do Sistema → Notificações.",
                    "Las notificaciones de Notch Limits están desactivadas en Ajustes del Sistema → Notificaciones."
                ))
                .secondaryText()
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
            HStack(spacing: 10) {
                iconMenu
                VStack(alignment: .leading, spacing: 2) {
                    nameField
                    Text("\(account.provider.title) · \(abbreviate(account.provider.path, home: model.home))")
                        .secondaryText()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(account.enabled ? 1 : 0.4)   // escondida fica apagada, como dado velho no painel
            Chip(account.enabled ? tr("Shown", "Visível", "Visible") : tr("Hidden", "Oculta", "Oculta"), on: account.enabled) {
                model.setEnabled(!account.enabled, id: account.id)
            }
            .accessibilityLabel(tr("Show \(account.name)", "Mostrar \(account.name)", "Mostrar \(account.name)"))
            .disabled(model.isLastShown(account.id))
            IconButton("chevron.up", label: tr("Move up", "Mover para cima", "Subir")) { model.move(id: account.id, by: -1) }
                .disabled(isFirst)
            IconButton("chevron.down", label: tr("Move down", "Mover para baixo", "Bajar")) { model.move(id: account.id, by: 1) }
                .disabled(isLast)
        }
    }

    /// Campo sem borda no estilo do nome no painel; a cápsula só aparece durante a edição, sem mover o texto
    private var nameField: some View {
        TextField(tr("Name", "Nome", "Nombre"), text: $draft, prompt: Text(tr("Name", "Nome", "Nombre")))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(Theme.title)
            .focused($editing)
            .onSubmit(commitName)
            .onChange(of: editing) { _, focused in if !focused { commitName() } }
            .onChange(of: account.name) { _, name in draft = name }
            .onAppear { draft = account.name }
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(editing ? Theme.fill : .clear, in: Capsule())
            .padding(.horizontal, -6)
    }

    /// O ícone da conta num botão de ícone; o menu que abre pode ser o do sistema
    private var iconMenu: some View {
        let known = ["claude", "codex"] + extraIcons.map(\.symbol)
        return Menu {
            let icon = Binding(get: { account.glyph.name }, set: { model.setIcon($0, id: account.id) })
            Picker(tr("Icon", "Ícone", "Icono"), selection: icon) {
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
                ForEach(extraIcons, id: \.symbol) { icon in
                    Label(icon.label, systemImage: icon.symbol).tag(icon.symbol)
                }
                // ícone próprio vindo do arquivo: aparece com o nome cru do símbolo
                if !known.contains(account.glyph.name) {
                    Text(account.glyph.name).tag(account.glyph.name)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            GlyphMark(glyph: account.glyph, tint: .white, size: 26)
                .iconFace(width: 30, height: 30)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(tr("Icon", "Ícone", "Icono"))
        .help(tr("Icon", "Ícone", "Icono"))
    }

    /// Volta ao nome salvo quando o campo fica vazio
    private func commitName() {
        model.rename(draft, id: account.id)
        draft = model.list.first { $0.id == account.id }?.name ?? draft
    }
}
