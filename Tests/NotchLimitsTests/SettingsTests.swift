import Foundation
import Testing
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
}
