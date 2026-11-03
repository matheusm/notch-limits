import Foundation
import Testing
@testable import NotchLimits

@Suite("Account discovery")
struct DiscoveryTests {
    /// Conta padrão: o estado fica em ~/.claude.json, fora de ~/.claude
    @Test func findsTheDefaultClaudeAccountFromTheStateFileInHome() {
        let home = TempDir(files: [".claude.json", ".claude/settings.json"])

        let found = discoverAccounts(home: home.path)

        #expect(found.map(\.name) == ["Claude"])
        #expect(found.map(\.provider.path) == ["\(home.path)/.claude"])
        #expect(found.map(\.glyph.name) == ["claude"])
        #expect(claudeStateFile(configDir: "\(home.path)/.claude", home: home.path) == "\(home.path)/.claude.json")
        #expect(claudeStateFile(configDir: "\(home.path)/.claude-work", home: home.path) == "\(home.path)/.claude-work/.claude.json")
    }

    /// Critério 1: sem accounts.json, a home do exemplo vira Claude, Claude Work e Codex, todas visíveis
    @Test func findsExtraClaudeDirsThatHaveTheirOwnStateFile() {
        let home = TempDir(files: [".claude.json", ".claude/settings.json", ".claude-work/.claude.json", ".codex/auth.json"])

        let accounts = loadAccounts(from: "\(home.path)/missing/accounts.json", home: home.path)

        #expect(accounts.map(\.name) == ["Claude", "Claude Work", "Codex"])
        #expect(accounts.map(\.provider.path) == ["\(home.path)/.claude", "\(home.path)/.claude-work", "\(home.path)/.codex"])
        #expect(accounts.map(\.enabled) == [true, true, true])
    }

    @Test func ignoresClaudeDirsWithoutAStateFileAndPlainFiles() {
        let home = TempDir(files: [".claude.json.backup", ".claude/settings.json", ".claude-code-router/config.json", ".claude-notes"])

        #expect(discoverAccounts(home: home.path).isEmpty)
    }

    @Test func findsCodexHomesThatHaveAuthJSON() {
        let home = TempDir(files: [".codex/auth.json", ".codex-team/auth.json", ".codex-old/config.toml", ".codex-auth.json"])

        let found = discoverAccounts(home: home.path)

        #expect(found.map(\.name) == ["Codex", "Codex Team"])
        #expect(found.map(\.provider.name) == ["codex", "codex"])
        #expect(found.map(\.provider.path) == ["\(home.path)/.codex", "\(home.path)/.codex-team"])
    }

    @Test func namesAndIconsFollowTheFolderSuffix() {
        let home = TempDir(files: [
            ".claude.json",
            ".claude-work/.claude.json",
            ".claude.alt/.claude.json",
            ".claude_acme/.claude.json",
            ".claude-my-team/.claude.json",
            ".codex/auth.json",
            ".codex-team/auth.json",
        ])

        let found = discoverAccounts(home: home.path)

        // só a primeira letra vira maiúscula; "-", "_" e "." do começo do sufixo somem
        #expect(found.map(\.name) == ["Claude", "Claude My-team", "Claude Work", "Claude Alt", "Claude Acme", "Codex", "Codex Team"])
        // a primeira conta de cada provedor leva o glifo dele; as demais seguem o rodízio de símbolos
        #expect(found.map(\.glyph.name) == [
            "claude", "leaf.fill", "briefcase.fill", "building.2.fill", "house.fill", "codex", "star.fill",
        ])
    }

    /// Sufixo só de separadores não vira o nome da conta padrão: fica o nome da pasta sem o ponto
    @Test func separatorOnlySuffixKeepsTheFolderName() {
        let home = TempDir(files: [".claude.json", ".claude_/.claude.json", ".codex/auth.json", ".codex-/auth.json"])

        #expect(discoverAccounts(home: home.path).map(\.name) == ["Claude", "claude_", "Codex", "codex-"])
    }

    @Test func iconRotationCyclesAndTheFirstFoundAccountGetsTheProviderGlyph() {
        let home = TempDir()
        for letter in "abcdefgh" { home.write(".claude-\(letter)/.claude.json", "{}") }

        let found = discoverAccounts(home: home.path)

        #expect(found.first?.name == "Claude A")
        #expect(found.map(\.glyph.name) == ["claude"] + extraIcons.map(\.symbol) + ["leaf.fill"])
    }

    @Test func ordersClaudeBeforeCodexAndSortsByFolderName() {
        let home = TempDir(files: [
            ".codex-b/auth.json", ".codex/auth.json", ".claude-z/.claude.json", ".claude-a/.claude.json", ".claude.json",
        ])

        #expect(discoverAccounts(home: home.path).map(\.name) == ["Claude", "Claude A", "Claude Z", "Codex", "Codex B"])
    }

    /// Critério 3: sem arquivo (ou com um array vazio) e sem nada encontrado, ficam os padrões de antes
    @Test func fallsBackToDefaultsWhenNothingIsFound() {
        let home = TempDir()

        for saved in [nil, []] as [[AccountConfig]?] {
            let accounts = mergeAccounts(saved: saved, discovered: [], home: home.path)
            #expect(accounts.map(\.name) == ["Claude", "Codex"])
            #expect(accounts.map(\.provider.path) == ["\(home.path)/.claude", "\(home.path)/.codex"])
            #expect(accounts.map(\.glyph.name) == ["claude", "codex"])
            #expect(accounts.map(\.enabled) == [true, true])
        }
    }

    /// Critério 4: o exemplo do README continua igual; o que a descoberta achar a mais entra escondido
    @Test func savedFileWinsAndNewFindsAreAddedHidden() throws {
        let home = TempDir(files: [
            ".claude.json",
            ".claude-work/.claude.json",
            ".claude-x/.claude.json",
            ".codex/auth.json",
            ".codex-team/auth.json",
        ])
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../accounts.example.json")
        let file = home.write("config/accounts.json", try String(contentsOf: example, encoding: .utf8))

        let accounts = loadAccounts(from: file, home: home.path)
        let shown = accounts.filter(\.enabled)

        #expect(shown.map(\.name) == ["Claude Personal", "Claude Work", "Codex"])
        #expect(shown.map(\.glyph.name) == ["claude", "briefcase.fill", "codex"])
        #expect(shown.map(\.provider.path) == ["\(home.path)/.claude", "\(home.path)/.claude-work", "\(home.path)/.codex"])
        #expect(accounts.map(\.name) == ["Claude Personal", "Claude Work", "Codex", "Claude X", "Codex Team"])
        #expect(accounts.map(\.enabled) == [true, true, true, false, false])
    }

    @Test func duplicateEntriesKeepTheFirst() {
        let home = TempDir()
        let saved = [
            AccountConfig(name: "Work", provider: "claude", path: "~/.claude-work"),
            AccountConfig(name: "Work again", provider: "claude", path: "\(home.path)/.claude-work/"),
            AccountConfig(name: "Codex here", provider: "codex", path: "~/.claude-work"),
        ]

        let accounts = mergeAccounts(saved: saved, discovered: [], home: home.path)

        #expect(accounts.map(\.name) == ["Work", "Codex here"])
    }

    /// Critério 8: um arquivo com tudo desligado ainda mostra a primeira conta
    @Test func allHiddenFileStillShowsTheFirstEntry() {
        let home = TempDir()
        let saved = [
            AccountConfig(name: "A", provider: "claude", enabled: false),
            AccountConfig(name: "B", provider: "codex", enabled: false),
        ]

        let accounts = mergeAccounts(saved: saved, discovered: [], home: home.path)

        #expect(accounts.map(\.enabled) == [true, false])
    }

    /// Critério 6: grava ~/… e "enabled": false só nas escondidas, sem escapar barras, e relê a mesma lista
    @Test func saveRoundTripsWithTildePathsAndEnabledFlag() throws {
        let home = TempDir()
        let file = "\(home.path)/.config/notch-limits/accounts.json"
        var hidden = Account(name: "Work", glyph: .symbol("briefcase.fill"), provider: .claude(configDir: "\(home.path)/.claude-work"))
        hidden.enabled = false
        let accounts = [
            Account(name: "Claude", glyph: .claude, provider: .claude(configDir: "\(home.path)/.claude")),
            hidden,
            Account(name: "Codex", glyph: .codex, provider: .codex(home: "/opt/codex")),
        ]

        try saveAccounts(accounts, to: file, home: home.path)

        let text = try String(contentsOfFile: file, encoding: .utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        #expect(json.map { $0["path"] as? String } == ["~/.claude", "~/.claude-work", "/opt/codex"])
        #expect(json.map { $0["enabled"] as? Bool } == [nil, false, nil])
        #expect(!text.contains("\\/"))
        #expect(text.contains("\n"))   // legível para quem edita à mão
        #expect(!FileManager.default.fileExists(atPath: "\(file).bak"))   // não havia original para guardar

        let loaded = loadAccounts(from: file, home: home.path)
        #expect(loaded.map(\.id) == accounts.map(\.id))
        #expect(loaded.map(\.name) == accounts.map(\.name))
        #expect(loaded.map(\.glyph.name) == accounts.map(\.glyph.name))
        #expect(loaded.map(\.enabled) == accounts.map(\.enabled))
    }

    @Test func firstSaveBacksUpTheHandWrittenFileOnlyOnce() throws {
        let home = TempDir()
        let original = #"[ { "name": "Mine", "provider": "claude" } ]"#
        let file = home.write(".config/notch-limits/accounts.json", original)
        let account = Account(name: "Claude", glyph: .claude, provider: .claude(configDir: "\(home.path)/.claude"))

        try saveAccounts([account], to: file, home: home.path)
        var renamed = account
        renamed.name = "Renamed"
        try saveAccounts([renamed], to: file, home: home.path)

        #expect(try String(contentsOfFile: "\(file).bak", encoding: .utf8) == original)
        #expect(loadAccounts(from: file, home: home.path).map(\.name) == ["Renamed"])
    }

    /// O .bak guarda só o que foi escrito à mão: um arquivo que o próprio app gravou não é copiado
    @Test func appWrittenFileIsNotBackedUp() throws {
        let home = TempDir()
        let file = "\(home.path)/.config/notch-limits/accounts.json"
        var account = Account(name: "Claude", glyph: .claude, provider: .claude(configDir: "\(home.path)/.claude"))

        try saveAccounts([account], to: file, home: home.path)
        account.name = "Renamed"
        try saveAccounts([account], to: file, home: home.path)
        #expect(!FileManager.default.fileExists(atPath: "\(file).bak"))

        // uma edição à mão depois disso é guardada na gravação seguinte
        let edited = #"[ { "name": "Edited by hand", "provider": "claude" } ]"#
        try edited.write(toFile: file, atomically: true, encoding: .utf8)
        try saveAccounts([account], to: file, home: home.path)
        #expect(try String(contentsOfFile: "\(file).bak", encoding: .utf8) == edited)
    }

    /// accounts.json ligado por symlink (dotfiles): grava no destino e mantém o link
    @Test func saveKeepsASymlinkedFileAndBacksUpItsContents() throws {
        let home = TempDir()
        let original = #"[ { "name": "Mine", "provider": "claude" } ]"#
        let target = home.write("dotfiles/accounts.json", original)
        let file = "\(home.path)/.config/notch-limits/accounts.json"
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(home.path)/.config/notch-limits", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: file, withDestinationPath: target)
        let account = Account(name: "Saved", glyph: .claude, provider: .claude(configDir: "\(home.path)/.claude"))

        try saveAccounts([account], to: file, home: home.path)

        #expect(try fm.destinationOfSymbolicLink(atPath: file) == target)
        #expect(loadAccounts(from: target, home: home.path).map(\.name) == ["Saved"])
        #expect(try fm.attributesOfItem(atPath: "\(file).bak")[.type] as? FileAttributeType == .typeRegular)
        #expect(try String(contentsOfFile: "\(file).bak", encoding: .utf8) == original)
    }

    /// QA: pasta de config ligada por symlink (dotfiles) conta como pasta; link quebrado não
    @Test func followsSymlinkedConfigDirsAndIgnoresDanglingOnes() throws {
        let home = TempDir(files: ["elsewhere/work/.claude.json"])
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: "\(home.path)/.claude-work", withDestinationPath: "\(home.path)/elsewhere/work")
        try fm.createSymbolicLink(atPath: "\(home.path)/.claude-gone", withDestinationPath: "\(home.path)/missing")

        let found = discoverAccounts(home: home.path)

        #expect(found.map(\.name) == ["Claude Work"])
        #expect(found.map(\.provider.path) == ["\(home.path)/.claude-work"])
    }

    /// QA: a conta padrão depende só de ~/.claude.json ser arquivo; ~/.claude/.claude.json não a cria
    @Test func defaultClaudeNeedsAStateFileInHomeNotInsideTheDir() throws {
        let home = TempDir(files: [".claude/.claude.json"])
        try FileManager.default.createDirectory(atPath: "\(home.path)/.claude.json", withIntermediateDirectories: true)

        #expect(discoverAccounts(home: home.path).isEmpty)
    }

    /// QA: um accounts.json escrito à mão (ícone próprio, caminho fora da home, campos omitidos ou desconhecidos)
    /// volta igual depois de gravado; o .bak guarda os bytes originais
    @Test func handWrittenFileRoundTripsThroughASave() throws {
        let home = TempDir()
        let original = """
        [
          { "name": "Personal", "provider": "claude", "path": "~/.claude", "icon": "claude", "note": "kept in .bak" },
          { "name": "Work", "provider": "claude", "path": "~/.claude-work/", "icon": "briefcase.fill" },
          { "name": "Codex", "provider": "codex" },
          { "name": "Gemini", "provider": "gemini" },
          { "name": "Custom", "provider": "claude", "path": "/Volumes/Work/claude", "icon": "cloud.fill", "enabled": false }
        ]
        """
        let file = home.write(".config/notch-limits/accounts.json", original)
        let before = loadAccounts(from: file, home: home.path)

        try saveAccounts(before, to: file, home: home.path)
        let after = loadAccounts(from: file, home: home.path)

        #expect(before.map(\.name) == ["Personal", "Work", "Codex", "Custom"])
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.name) == before.map(\.name))
        #expect(after.map(\.glyph.name) == ["claude", "briefcase.fill", "codex", "cloud.fill"])
        #expect(after.map(\.enabled) == [true, true, true, false])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [[String: Any]])
        #expect(json.map { $0["path"] as? String } == ["~/.claude", "~/.claude-work", "~/.codex", "/Volumes/Work/claude"])
        #expect(json.allSatisfy { $0["note"] == nil })
        #expect(try String(contentsOfFile: "\(file).bak", encoding: .utf8) == original)
    }

    /// QA: só caminhos dentro da home viram ~/…; um vizinho com o mesmo prefixo não
    @Test func abbreviateOnlyShortensPathsInsideHome() {
        #expect(abbreviate("/Users/me", home: "/Users/me") == "~")
        #expect(abbreviate("/Users/me/.claude-work", home: "/Users/me") == "~/.claude-work")
        #expect(abbreviate("/Users/me2/.claude", home: "/Users/me") == "/Users/me2/.claude")
        #expect(expand("~", home: "/Users/me") == "/Users/me")
        #expect(expand("~/", home: "/Users/me") == "/Users/me")
        #expect(expand("/opt/codex//", home: "/Users/me") == "/opt/codex")
    }

    @Test func accountIdsAreProviderAndPath() {
        let home = TempDir()
        let saved = [
            AccountConfig(name: "Work", provider: "claude", path: "~/.claude-work/"),
            AccountConfig(name: "Codex", provider: "codex"),
        ]

        let ids = mergeAccounts(saved: saved, discovered: [], home: home.path).map(\.id)

        #expect(ids == ["claude:\(home.path)/.claude-work", "codex:\(home.path)/.codex"])
    }
}
