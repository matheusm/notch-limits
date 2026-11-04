import SwiftUI
import ServiceManagement

// Painel da barra de menu: aparece quando não há tela com notch ou o chip Notch está desligado.
// É o próprio conteúdo do notch expandido (linhas, Melhor agora, ritmo, chips, botões de ícone) sobre o mesmo preto,
// nunca uma segunda versão; fica escuro mesmo com o sistema no modo claro

struct ContentView: View {
    @ObservedObject var store: Store
    let launchAtLogin: Bool
    let defaults: UserDefaults

    /// Login e defaults entram por fora para os snapshots não lerem o sistema
    init(store: Store, launchAtLogin: Bool = SMAppService.mainApp.status == .enabled, defaults: UserDefaults = .standard) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        self.defaults = defaults
    }

    var body: some View {
        NotchDetailView(
            store: store,
            openSettings: { SettingsWindow.shared.show(store: store) },   // não fecha por código: MenuBarExtra não tem API para isso
            launchAtLogin: launchAtLogin,
            defaults: defaults
        )
        .padding(.top, 8)   // no notch o detalhe começa abaixo da faixa do notch; aqui, abaixo da borda da janela
        .frame(width: Theme.panelWidth)
        .background(Theme.ground)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)   // pede escura também a moldura do MenuBarExtra, que é do sistema
        .onAppear { Task { await store.refresh(network: false) } }
    }
}
