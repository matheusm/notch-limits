import SwiftUI
import Testing
@testable import NotchLimits

// Prints do app para o site: os dados de exemplo dos Snapshots, sobre o --ground-lift do site (#101215) para o PNG se
// fundir com a moldura da página. O inglês vem do processo (-AppleLanguages), por isso rode só via scripts/site-shots.sh.
// Ferramenta, não gate: sem SNAPSHOT_DIR a suíte não roda (D-023).

@MainActor
@Suite("SiteShots", .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil), .serialized)
struct SiteShots {
    let fixtures = Snapshots()
    let ground = Color(red: 0x10 / 255, green: 0x12 / 255, blue: 0x15 / 255)

    /// Painel aberto com as três contas: "Best now", ritmo em laranja e o ritmo neutro do Codex
    @Test func notchPanel() throws {
        let model = NotchModel()
        model.expanded = true
        let panel = NotchView(
            store: fixtures.fixtureStore(),
            model: model,
            openSettings: {},
            launchAtLogin: { true },
            defaults: fixtures.defaults
        )
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 36)
        .padding(.bottom, 36)
        .background(ground)
        try Snapshot.render(panel, backdrop: false, appearance: nil, name: "site-notch-panel")
    }

    /// Ajustes com as três contas encontradas, todas visíveis, e as notificações ligadas
    @Test func settings() async throws {
        let home = fixtures.settingsHome()
        let settings = AccountSettings(file: home.file, home: home.dir.path) { _ in }
        settings.reload()
        let on = fixtures.notifications(on: true)
        await on.reload()
        try fixtures.renderSettings(settings, notifications: on, name: "site-settings")
    }
}
