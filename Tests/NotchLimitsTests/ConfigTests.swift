import Foundation
import Testing
@testable import NotchLimits

@Suite("accounts.json")
struct ConfigTests {
    @Test func defaultsToClaudeAndCodexWithoutConfig() {
        let accounts = loadAccounts(from: "/nonexistent/accounts.json")

        #expect(accounts.map(\.name) == ["Claude", "Codex"])
        #expect(accounts.map(\.provider.path) == ["\(home)/.claude", "\(home)/.codex"])
        #expect(accounts.map(\.glyph.name) == ["claude", "codex"])
    }

    @Test func fallsBackToDefaultsOnInvalidJSON() {
        let dir = TempDir()
        let file = dir.write("accounts.json", "{ not json")

        #expect(loadAccounts(from: file).map(\.name) == ["Claude", "Codex"])
    }

    @Test func parsesAccountsExpandingPathsAndSkippingUnknownProviders() {
        let dir = TempDir()
        let file = dir.write("accounts.json", """
        [
          { "name": "Work", "provider": "claude", "path": "~/.claude-work/", "icon": "leaf.fill" },
          { "name": "Other", "provider": "gemini" },
          { "name": "Codex", "provider": "codex", "path": "/opt/codex" }
        ]
        """)

        let accounts = loadAccounts(from: file)

        #expect(accounts.map(\.name) == ["Work", "Codex"])
        #expect(accounts.map(\.provider.name) == ["claude", "codex"])
        #expect(accounts.map(\.provider.path) == ["\(home)/.claude-work", "/opt/codex"])
        #expect(accounts.map(\.glyph.name) == ["leaf.fill", "codex"])
    }

    /// Mesmo nome de item que o Claude Code usa no Keychain para cada CLAUDE_CONFIG_DIR
    @Test func keychainServiceMatchesClaudeCode() {
        #expect(keychainService(for: "\(home)/.claude") == "Claude Code-credentials")
        #expect(keychainService(for: "/Users/me/.claude-work") == "Claude Code-credentials-1e91dd84")
    }
}
