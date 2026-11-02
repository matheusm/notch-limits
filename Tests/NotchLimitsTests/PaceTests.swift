import Foundation
import Testing
@testable import NotchLimits

@Suite("Pace")
struct PaceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = WindowKind.session(hours: 5)

    func hours(_ count: Double) -> Date { now.addingTimeInterval(count * 3600) }

    /// Ritmo de uma janela lida em `observed` (padrão: agora)
    func pace(_ limit: LimitWindow, observed: Date? = nil) -> Pace? {
        NotchLimits.pace(of: limit, in: Usage(windows: [limit], updatedAt: observed ?? now), now: now)
    }

    /// Critério 1
    @Test(arguments: [
        (WindowKind.session(hours: 5), 5 * 3600.0),
        (.session(hours: 0), nil),
        (.weekly, 7 * 86_400),
        (.weeklyModel("Opus"), 7 * 86_400),
        (.days(2), 2 * 86_400),
        (.days(0), nil),
    ] as [(WindowKind, TimeInterval?)])
    func windowDurationComesFromItsKind(kind: WindowKind, duration: TimeInterval?) {
        #expect(window(kind).duration == duration)
    }

    /// Critério 2: sessão de 5 h que reseta em 3 h começou há 2 h → 40%; semana com 5d6h pela frente → 25%
    @Test func expectedTickIsTheElapsedShareOfTheWindow() {
        #expect(pace(window(session, 10, resetsAt: hours(3)))?.expected == 40)
        #expect(pace(window(.weekly, 10, resetsAt: hours(5 * 24 + 6)))?.expected == 25)
    }

    /// Critério 3, exemplo do spec: 80% em 2 h de sessão → 100% em 2h30 do início, 30 min a partir de agora
    @Test func projectsTheLimitTimeWhenThePaceReachesOneHundred() {
        #expect(pace(window(session, 80, resetsAt: hours(3))) == Pace(expected: 40, limitAt: hours(0.5)))
    }

    /// Critério 3: 30% em 2 h chegaria a 100% em 6h40, depois do reset
    @Test func noLineWhenThePaceMakesItToTheReset() {
        #expect(pace(window(session, 30, resetsAt: hours(3))) == Pace(expected: 40, limitAt: nil))
    }

    /// Critério 4: 15% de uma sessão de 5 h são 45 min; com 44 min nenhuma projeção, por mais alto que esteja o uso
    @Test func noProjectionInTheFirstFifteenPercentOfTheWindow() {
        let before = pace(window(session, 50, resetsAt: hours(5 - 44 / 60.0)))
        let at = pace(window(session, 50, resetsAt: hours(5 - 45 / 60.0)))

        #expect(before?.expected != nil)
        #expect(before?.limitAt == nil)
        #expect(at?.limitAt == hours(45 / 60.0))   // 50% em 45 min → 100% em 90 min do início
    }

    /// Critério 5: o percentual foi medido 5 min atrás: 80% em 1h55 → 100% em 2h23m45 do início
    @Test func usesTheSnapshotTimeForTheRate() {
        let observed = now.addingTimeInterval(-5 * 60)

        #expect(pace(window(session, 80, resetsAt: hours(3)), observed: observed)?.limitAt == hours(-2).addingTimeInterval(8625))
    }

    /// Critério 6: sem reset (sessão inativa), reset agora ou no passado
    @Test func noPaceWithoutAFutureResetTime() {
        #expect(pace(window(session, 80)) == nil)
        #expect(pace(window(session, 80, resetsAt: now)) == nil)
        #expect(pace(window(session, 80, resetsAt: hours(-1))) == nil)
    }

    /// Critério 6: barra velha ao lado de um traço atual enganaria
    @Test func noPaceForStaleOrEmptyUsage() {
        let limit = window(session, 80, resetsAt: hours(3))

        #expect(pace(limit, observed: now.addingTimeInterval(-16 * 60)) == nil)
        #expect(NotchLimits.pace(of: limit, in: Usage(updatedAt: now), now: now) == nil)
        #expect(NotchLimits.pace(of: limit, in: Usage(windows: [limit]), now: now) == nil)
    }

    /// Critério 6: reset em 6 h numa sessão de 5 h → a janela começaria daqui a 1 h; o tamanho suposto está errado
    @Test func noPaceWhenTheWindowWouldStartInTheFuture() {
        #expect(pace(window(session, 10, resetsAt: hours(6))) == nil)
    }

    /// QA: as janelas reais do Codex (5 h e 7 d, em minutos no snapshot local e em segundos na API) têm o tamanho exato
    @Test func realCodexWindowLengthsGiveExactDurations() {
        func local(_ minutes: Int) -> TimeInterval? {
            codexWindow(["used_percent": 10.0, "window_minutes": minutes], minutesKey: "window_minutes", secondsKey: "", resetKey: "")?
                .duration
        }
        func api(_ seconds: Int) -> TimeInterval? {
            let raw: [String: Any] = ["used_percent": 10.0, "limit_window_seconds": seconds]
            return codexWindow(raw, minutesKey: "", secondsKey: "limit_window_seconds", resetKey: "")?.duration
        }
        let session: TimeInterval = 18_000, week: TimeInterval = 604_800

        #expect(local(300) == session)
        #expect(local(10_080) == week)
        #expect(api(18_000) == session)
        #expect(api(604_800) == week)
        #expect(local(0) == nil)
    }

    /// QA: snapshot lido antes do início da janela atual (ainda fresco): o traço aparece, a projeção não
    @Test func aSnapshotFromBeforeTheWindowStartNeverProjects() {
        let limit = window(session, 50, resetsAt: hours(5 - 5 / 60.0))   // a janela começou há 5 min
        let result = pace(limit, observed: now.addingTimeInterval(-10 * 60))

        #expect(result?.expected != nil)
        #expect(result?.limitAt == nil)
    }

    /// Critério 6: em 100% ou mais (ou em 0%) fica só o traço
    @Test func noLineAtOrAboveOneHundredPercent() {
        #expect(pace(window(session, 100, resetsAt: hours(3))) == Pace(expected: 40, limitAt: nil))
        #expect(pace(window(session, 120, resetsAt: hours(3))) == Pace(expected: 40, limitAt: nil))
        #expect(pace(window(session, 0, resetsAt: hours(3))) == Pace(expected: 40, limitAt: nil))
    }
}
