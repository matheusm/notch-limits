import Foundation
import Testing
import UserNotifications
@testable import NotchLimits

@MainActor
@Suite("Settings window")
struct SettingsTests {
    let home = TempDir(files: [".claude.json", ".claude-work/.claude.json", ".codex/auth.json"])
    var file: String { "\(home.path)/.config/notch-limits/accounts.json" }

    /// Guarda cada lista aplicada ao Store
    final class Applied {
        var lists: [[Account]] = []
    }

    func makeSettings(_ applied: Applied) -> AccountSettings {
        let settings = AccountSettings(file: file, home: home.path) { applied.lists.append($0) }
        settings.reload()
        return settings
    }

    @Test func openingSettingsAppliesTheFoundAccountsWithoutWritingTheFile() {
        let applied = Applied()
        let settings = makeSettings(applied)

        #expect(settings.list.map(\.name) == ["Claude", "Claude Work", "Codex"])
        #expect(applied.lists.map { $0.map(\.name) } == [["Claude", "Claude Work", "Codex"]])
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func everyCommittedChangeIsSavedAndApplied() {
        let applied = Applied()
        let settings = makeSettings(applied)
        let work = settings.list[1].id

        settings.rename("  Team  ", id: work)
        settings.setIcon("star.fill", id: work)
        settings.move(id: work, by: -1)
        settings.setEnabled(false, id: settings.list[2].id)

        let expected = ["Team", "Claude", "Codex"]
        #expect(settings.list.map(\.name) == expected)
        #expect(settings.saveError == nil)
        #expect(applied.lists.count == 5)
        #expect(applied.lists.last?.map(\.enabled) == [true, true, false])
        let saved = loadAccounts(from: file, home: home.path)
        #expect(saved.map(\.name) == expected)
        #expect(saved.map(\.glyph.name) == ["star.fill", "claude", "codex"])
        #expect(saved.map(\.enabled) == [true, true, false])
    }

    /// Critério 8: a última conta visível não pode ser escondida
    @Test func lastShownAccountCannotBeHidden() {
        let settings = makeSettings(Applied())
        let ids = settings.list.map(\.id)

        settings.setEnabled(false, id: ids[0])
        settings.setEnabled(false, id: ids[1])
        #expect(settings.isLastShown(ids[2]))
        #expect(!settings.isLastShown(ids[0]))
        settings.setEnabled(false, id: ids[2])

        #expect(settings.list.map(\.enabled) == [false, false, true])
    }

    @Test func emptyNameKeepsThePreviousOne() {
        let applied = Applied()
        let settings = makeSettings(applied)

        settings.rename("   ", id: settings.list[0].id)
        settings.rename("Claude", id: settings.list[0].id)

        #expect(settings.list[0].name == "Claude")
        #expect(applied.lists.count == 1)   // nada mudou: nada gravado nem aplicado
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    /// QA: subir a primeira ou descer a última não muda, não grava nem aplica nada
    @Test func movingPastTheEdgesChangesNothing() {
        let applied = Applied()
        let settings = makeSettings(applied)

        settings.move(id: settings.list[0].id, by: -1)
        settings.move(id: settings.list[2].id, by: 1)

        #expect(settings.list.map(\.name) == ["Claude", "Claude Work", "Codex"])
        #expect(applied.lists.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    /// QA: abrir de novo relê o arquivo editado à mão e a home (pasta nova entra escondida, pois o arquivo existe)
    @Test func reopeningPicksUpHandEditsAndNewFolders() {
        let applied = Applied()
        let settings = makeSettings(applied)
        settings.rename("Personal", id: settings.list[0].id)

        home.write(".config/notch-limits/accounts.json", #"[ { "name": "Edited", "provider": "codex" } ]"#)
        home.write(".claude-new/.claude.json", "{}")
        settings.reload()

        #expect(settings.list.map(\.name) == ["Edited", "Claude", "Claude New", "Claude Work"])
        #expect(settings.list.map(\.enabled) == [true, false, false, false])
        #expect(applied.lists.last?.filter(\.enabled).map(\.name) == ["Edited"])
    }

    @Test func aFailedSaveKeepsTheChangeAndShowsTheError() {
        home.write(".config", "a file where the folder should be")
        let applied = Applied()
        let settings = makeSettings(applied)

        settings.rename("Personal", id: settings.list[0].id)

        #expect(settings.list[0].name == "Personal")
        #expect(applied.lists.last?.first?.name == "Personal")
        #expect(settings.saveError != nil)
    }

    /// QA do R-05: a engrenagem relê o disco, então o erro de uma gravação anterior não vale mais
    @Test func rereadingTheFileClearsAnOldSaveError() {
        home.write(".config", "a file where the folder should be")
        let settings = makeSettings(Applied())
        settings.rename("Personal", id: settings.list[0].id)
        #expect(settings.saveError != nil)

        settings.reload()

        #expect(settings.list[0].name == "Claude")
        #expect(settings.saveError == nil)
    }
}

/// Permissão e toggle falsos: nenhum teste toca a Central de Notificações nem o UserDefaults real
@MainActor
final class FakePermission {
    var granted = false
    var status = UNAuthorizationStatus.authorized
    var prompt: Gate?            // segura a resposta do pedido de permissão até o teste liberar
    var asked = 0
    var saved: [Bool] = []

    func makeSettings(isOn: Bool) -> NotificationSettings {
        NotificationSettings(
            isOn: isOn,
            save: { self.saved.append($0) },
            requestPermission: {
                self.asked += 1
                await self.prompt?.wait()
                return self.granted
            },
            authorization: { self.status }
        )
    }
}

@MainActor
@Suite("Notification settings")
struct NotificationSettingsTests {
    @Test func turningNotificationsOnAsksForPermissionAndStaysOnWhenAllowed() async {
        let fake = FakePermission()
        fake.granted = true
        let settings = fake.makeSettings(isOn: false)

        await settings.setOn(true)

        #expect(fake.asked == 1)
        #expect(settings.isOn && !settings.denied)
        #expect(fake.saved == [true])
    }

    /// Critério 10 (lógica): negar devolve o toggle para desligado e mostra a legenda
    @Test func deniedPermissionTurnsTheToggleBackOffAndShowsTheCaption() async {
        let fake = FakePermission()
        let settings = fake.makeSettings(isOn: false)

        await settings.setOn(true)

        #expect(fake.asked == 1)
        #expect(!settings.isOn && settings.denied)
        #expect(fake.saved == [false])
    }

    @Test func turningNotificationsOffNeverAsks() async {
        let fake = FakePermission()
        let settings = fake.makeSettings(isOn: true)

        await settings.setOn(false)

        #expect(fake.asked == 0)
        #expect(!settings.isOn && !settings.denied)
        #expect(fake.saved == [false])
    }

    /// Abrir os Ajustes com o toggle ligado e as notificações desligadas no sistema mostra a legenda, sem pedir de novo
    @Test func openingSettingsShowsTheCaptionWhenTheSystemDenies() async {
        let fake = FakePermission()
        fake.status = .denied
        let on = fake.makeSettings(isOn: true)
        let off = fake.makeSettings(isOn: false)

        await on.reload()
        await off.reload()

        #expect(on.isOn && on.denied)
        #expect(!off.denied)
        #expect(fake.asked == 0)
    }

    /// QA: permissão zerada no sistema (nunca respondida) com o toggle gravado ligado: abrir os Ajustes mostra desligado,
    /// e ligar de novo volta a pedir
    @Test func openingSettingsTurnsTheToggleOffWhenPermissionWasNeverAnswered() async {
        let fake = FakePermission()
        fake.status = .notDetermined
        fake.granted = true
        let settings = fake.makeSettings(isOn: true)

        await settings.reload()
        #expect(!settings.isOn && !settings.denied)
        #expect(fake.saved == [false])

        await settings.setOn(true)
        #expect(fake.asked == 1)
        #expect(settings.isOn)
    }

    /// Abrir os Ajustes com o pedido do macOS ainda na tela (permissão ainda não respondida) não desliga o toggle
    @Test func openingSettingsWhileThePromptIsUpKeepsTheToggleOn() async {
        let fake = FakePermission()
        fake.status = .notDetermined
        fake.granted = true
        fake.prompt = Gate()
        let settings = fake.makeSettings(isOn: false)

        let asking = Task { await settings.setOn(true) }
        while fake.asked == 0 { await Task.yield() }
        await settings.reload()
        #expect(settings.isOn)
        fake.prompt?.open()
        await asking.value

        #expect(settings.isOn && !settings.denied)
        #expect(fake.saved == [true])
    }

    /// QA: desligar com o pedido do macOS ainda na tela e depois clicar em Permitir não religa o toggle
    @Test func aPermissionAnswerAfterANewerToggleChangeIsIgnored() async {
        let fake = FakePermission()
        fake.granted = true
        fake.prompt = Gate()
        let settings = fake.makeSettings(isOn: false)

        let asking = Task { await settings.setOn(true) }
        while fake.asked == 0 { await Task.yield() }
        await settings.setOn(false)
        fake.prompt?.open()
        await asking.value

        #expect(!settings.isOn && !settings.denied)
        #expect(fake.saved == [false])
    }
}
