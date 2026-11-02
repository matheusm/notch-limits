import Foundation
import Testing
@testable import NotchLimits

@Suite("Snapshots locais dos CLIs")
struct LocalSnapshotTests {
    @Test func readsClaudeCodeUsageCache() {
        let dir = TempDir()
        dir.write(".claude-test/.claude.json", """
        { "cachedUsageUtilization": {
            "fetchedAtMs": 1793647131940,
            "utilization": { "limits": [ { "kind": "weekly_all", "percent": 16, "resets_at": "2026-11-03T01:00:00+00:00" } ] }
        } }
        """)

        let usage = localClaude(configDir: "\(dir.path)/.claude-test")

        #expect(usage?.updatedAt == Date(timeIntervalSince1970: 1_793_647_131.94))
        #expect(usage?.windows.map(\.kind) == [.weekly])
        #expect(usage?.peak == 16)
    }

    @Test func claudeWithoutCacheIsNil() {
        let dir = TempDir()
        dir.write(".claude-test/.claude.json", #"{ "numStartups": 3 }"#)

        #expect(localClaude(configDir: "\(dir.path)/.claude-test") == nil)
        #expect(localClaude(configDir: "\(dir.path)/missing") == nil)
    }

    /// Pega o último rate_limits do arquivo de sessão mais recente, ignorando eventos sem limites
    @Test func readsLatestCodexRateLimits() {
        let dir = TempDir()
        let event = { (time: String, pct: Double) in
            #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(pct),"window_minutes":10080,"resets_at":1793793564},"secondary":null,"plan_type":"prolite"}}}"#
        }
        dir.write("sessions/2026/11/01/rollout-old.jsonl", event("2026-11-01T10:00:00.000Z", 20), modified: Date(timeIntervalSinceNow: -86_400))
        dir.write("sessions/2026/11/02/rollout-new.jsonl", [
            event("2026-11-02T19:00:00.000Z", 30),
            event("2026-11-02T19:38:07.977Z", 36),
            #"{"timestamp":"2026-11-02T19:39:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#,
            #"{"timestamp":"2026-11-02T19:40:00.000Z","type":"response_item","payload":{}}"#,
        ].joined(separator: "\n"))

        let usage = localCodex(codexHome: dir.path)

        #expect(usage?.windows.map(\.kind) == [.weekly])
        #expect(usage?.peak == 36)
        #expect(usage?.plan == "prolite")
        #expect(usage?.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_793_793_564))
        #expect(usage.flatMap(\.updatedAt).map { abs($0.timeIntervalSince1970 - 1_793_648_287.977) < 0.01 } == true)
    }

    @Test func codexWithoutSessionsIsNil() {
        #expect(localCodex(codexHome: TempDir().path) == nil)
    }
}
