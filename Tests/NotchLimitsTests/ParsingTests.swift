import Foundation
import Testing
@testable import NotchLimits

@Suite("Respostas das APIs")
struct ParsingTests {
    @Test func claudeLimitsMapToWindowKinds() {
        let windows = claudeWindows([
            "limits": [
                ["kind": "session", "percent": 12.0, "resets_at": NSNull()],
                ["kind": "weekly_all", "percent": 16.0, "resets_at": "2026-11-03T01:00:00.841086+00:00"],
                ["kind": "weekly_scoped", "percent": 10.0, "resets_at": "2026-11-03T14:00:00+00:00",
                 "scope": ["model": ["display_name": "Fable"]]],
                ["kind": "weekly_scoped", "resets_at": NSNull()],   // sem percent: ignorado
            ],
        ])

        #expect(windows.map(\.kind) == [.session(hours: 5), .weekly, .weeklyModel("Fable")])
        #expect(windows.map(\.percent) == [12, 16, 10])
        #expect(windows[0].resetsAt == nil)
        #expect(windows[1].resetsAt.map { abs($0.timeIntervalSince1970 - 1_793_667_600.841) < 0.01 } == true)
        #expect(windows[2].resetsAt == Date(timeIntervalSince1970: 1_793_714_400))
    }

    /// Resposta antiga, sem o array "limits"
    @Test func claudeFallsBackToFiveHourAndSevenDay() {
        let windows = claudeWindows([
            "five_hour": NSNull(),
            "seven_day": ["utilization": 8.0, "resets_at": "2026-11-03T14:00:00+00:00"],
        ])

        #expect(windows.map(\.kind) == [.weekly])
        #expect(windows.map(\.percent) == [8])
    }

    @Test(arguments: [
        // janela da API (limit_window_seconds) ou da sessão local do Codex (window_minutes) → tipo esperado
        (["used_percent": 36.0, "limit_window_seconds": 604_800], WindowKind.weekly),
        (["used_percent": 36.0, "limit_window_seconds": 18_000], .session(hours: 5)),
        (["used_percent": 36.0, "limit_window_seconds": 172_800], .days(2)),
        (["used_percent": 36.0, "window_minutes": 300], .session(hours: 5)),
    ] as [([String: Any], WindowKind)])
    func codexWindowLengthMapsToKind(raw: [String: Any], kind: WindowKind) {
        let w = codexWindow(raw, minutesKey: "window_minutes", secondsKey: "limit_window_seconds", resetKey: "reset_at")
        #expect(w?.kind == kind)
        #expect(w?.percent == 36)
    }

    @Test func codexWindowWithoutPercentIsSkipped() {
        #expect(codexWindow(["limit_window_seconds": 18_000], minutesKey: "", secondsKey: "limit_window_seconds", resetKey: "") == nil)
        #expect(codexWindow(nil, minutesKey: "", secondsKey: "", resetKey: "") == nil)
    }

    @Test func httpStatusMapsToErrors() {
        #expect(httpError(status: 200, retryAfter: nil) == nil)
        #expect(httpError(status: 401, retryAfter: nil)?.retryAfter == nil)
        #expect(httpError(status: 401, retryAfter: nil)?.errorDescription == httpError(status: 403, retryAfter: nil)?.errorDescription)
        #expect(httpError(status: 500, retryAfter: nil)?.errorDescription == "HTTP 500")
    }

    @Test func rateLimitHonorsRetryAfter() {
        #expect(httpError(status: 429, retryAfter: "222")?.retryAfter == 222)
        #expect(httpError(status: 429, retryAfter: nil)?.retryAfter == 300)
        #expect(httpError(status: 429, retryAfter: "soon")?.retryAfter == 300)
    }
}
