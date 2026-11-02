import Foundation
import Testing
@testable import NotchLimits

/// Estado carregado de uma leitura para a seguinte, como o LimitNotifier faz entre refreshes
struct AlertRun {
    var state: [AlertKey: AlertState] = [:]

    mutating func step(_ accounts: [Account], _ usage: [String: Usage], at now: Date) -> [LimitAlert] {
        let result = limitAlerts(previous: state, accounts: accounts, usage: usage, now: now)
        state = result.state
        return result.alerts
    }
}

@Suite("Limit alerts")
struct AlertTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let work = Account(name: "Claude Work", glyph: .claude, provider: .claude(configDir: "/h/.claude-work"))
    let codex = Account(name: "Codex", glyph: .codex, provider: .codex(home: "/h/.codex"))
    let session = WindowKind.session(hours: 5)

    func minutes(_ count: Double) -> Date { now.addingTimeInterval(count * 60) }

    /// Snapshot da conta work lido em `time` (updatedAt = time, ou seja, fresco)
    func read(_ windows: LimitWindow..., at time: Date) -> [String: Usage] {
        [work.id: Usage(windows: windows, updatedAt: time)]
    }

    /// Leituras frescas da janela de sessão da conta work, uma por minuto, com o mesmo horário de reset
    func sessionSteps(_ percents: [Double], resetsAt: Date, run: inout AlertRun) -> [[LimitAlert]] {
        percents.enumerated().map { index, percent in
            let time = minutes(Double(index))
            return run.step([work], read(window(session, percent, resetsAt: resetsAt), at: time), at: time)
        }
    }

    @Test func firstReadingNeverAlertsEvenAboveNinety() {
        var run = AlertRun()
        let steps = sessionSteps([95, 96], resetsAt: minutes(60), run: &run)

        #expect(steps == [[], []])
        #expect(run.state[AlertKey(account: work.id, window: session)]?.warned == true)
    }

    /// Critério 1
    @Test func crossingNinetyAlertsOnce() {
        var run = AlertRun()
        let steps = sessionSteps([85, 90], resetsAt: minutes(60), run: &run)

        #expect(steps == [[], [.nearLimit(account: work.id, window: session)]])
    }

    @Test func seventyPercentNeverAlerts() {
        var run = AlertRun()
        let steps = sessionSteps([50, 70, 89, 89.9], resetsAt: minutes(60), run: &run)

        #expect(steps.flatMap { $0 }.isEmpty)
    }

    /// Critério 2
    @Test func stayingAboveNinetyDoesNotRepeat() {
        var run = AlertRun()
        let steps = sessionSteps([85, 91, 95, 99, 100], resetsAt: minutes(60), run: &run)

        #expect(steps.flatMap { $0 } == [.nearLimit(account: work.id, window: session)])
    }

    /// Critério 2: oscilar entre local e API (90.2 → 89.8 → 91) não é um novo cruzamento
    @Test func dippingUnderNinetyWithoutAResetDoesNotRearm() {
        var run = AlertRun()
        let steps = sessionSteps([85, 90.2, 89.8, 91], resetsAt: minutes(60), run: &run)

        #expect(steps.flatMap { $0 } == [.nearLimit(account: work.id, window: session)])
    }

    /// Critério 3: o snapshot ainda mostra 95% depois do reset; o horário basta, e só uma vez
    @Test func resetAlertsAvailableAgainAtTheResetTimeEvenWithAnOldSnapshot() {
        var run = AlertRun()
        let old = read(window(session, 95, resetsAt: minutes(3)), at: now)

        #expect(run.step([work], old, at: now).isEmpty)
        #expect(run.step([work], old, at: minutes(1)).isEmpty)
        #expect(run.step([work], old, at: minutes(3)) == [.availableAgain(account: work.id, window: session)])
        #expect(run.step([work], old, at: minutes(4)).isEmpty)
        #expect(run.step([work], read(window(session, 2, resetsAt: minutes(300)), at: minutes(5)), at: minutes(5)).isEmpty)
    }

    /// Critério 4: a sessão reseta com a semanal ainda em 95%; o aviso sai só no reset da semanal
    @Test func resetIsNotAnnouncedWhileAnotherWindowIsStillAtNinety() {
        var run = AlertRun()
        let weeklyReset = minutes(3 * 24 * 60)
        let first = read(window(session, 92, resetsAt: minutes(3)), window(.weekly, 95, resetsAt: weeklyReset), at: now)
        let later = read(window(session, 10, resetsAt: weeklyReset + 7200), window(.weekly, 95, resetsAt: weeklyReset), at: weeklyReset)

        #expect(run.step([work], first, at: now).isEmpty)
        #expect(run.step([work], first, at: minutes(3)).isEmpty)
        #expect(run.step([work], later, at: weeklyReset) == [.availableAgain(account: work.id, window: .weekly)])
    }

    /// Critério 5
    @Test func warningRearmsAfterTheWindowResets() {
        var run = AlertRun()
        let near = LimitAlert.nearLimit(account: work.id, window: session)
        let steps = sessionSteps([85, 92], resetsAt: minutes(2), run: &run)
        let atReset = run.step([work], read(window(session, 92, resetsAt: minutes(2)), at: minutes(1)), at: minutes(2))
        let nextPeriod = [50.0, 93].map { percent in
            run.step([work], read(window(session, percent, resetsAt: minutes(300)), at: minutes(5)), at: minutes(5))
        }

        #expect(steps == [[], [near]])
        #expect(atReset == [.availableAgain(account: work.id, window: session)])
        #expect(nextPeriod == [[], [near]])
    }

    /// Avisou, caiu para 89% e o período acabou: sem "disponível de novo" (não estava em 90%), mas o próximo período avisa
    @Test func aWindowThatDippedBeforeItsResetCanWarnInTheNextPeriod() {
        var run = AlertRun()
        let steps = sessionSteps([85, 92, 89], resetsAt: minutes(3), run: &run)
        let atReset = run.step([work], read(window(session, 5, resetsAt: minutes(300)), at: minutes(3)), at: minutes(3))
        let crossing = run.step([work], read(window(session, 93, resetsAt: minutes(300)), at: minutes(4)), at: minutes(4))

        #expect(steps.flatMap { $0 } == [.nearLimit(account: work.id, window: session)])
        #expect(atReset.isEmpty)
        #expect(crossing == [.nearLimit(account: work.id, window: session)])
    }

    /// Critério 7: uma por conta, a da janela mais alta, na ordem das contas
    @Test func windowsCrossingTogetherSendOneAlertPerAccount() {
        var run = AlertRun()
        let accounts = [work, codex]
        func both(session sessionPercent: Double, weekly: Double, codex codexPercent: Double) -> [String: Usage] {
            [
                work.id: Usage(windows: [window(session, sessionPercent, resetsAt: minutes(60)), window(.weekly, weekly)], updatedAt: now),
                codex.id: Usage(windows: [window(.weekly, codexPercent, resetsAt: minutes(600))], updatedAt: now),
            ]
        }

        #expect(run.step(accounts, both(session: 80, weekly: 85, codex: 50), at: now).isEmpty)
        #expect(run.step(accounts, both(session: 93, weekly: 96, codex: 91), at: now) == [
            .nearLimit(account: work.id, window: .weekly),
            .nearLimit(account: codex.id, window: .weekly),
        ])
    }

    @Test func windowsResettingTogetherSendOneAvailableAgain() {
        var run = AlertRun()
        let both = read(window(session, 92, resetsAt: minutes(3)), window(.weekly, 97, resetsAt: minutes(3)), at: now)

        #expect(run.step([work], both, at: now).isEmpty)
        #expect(run.step([work], both, at: minutes(3)) == [.availableAgain(account: work.id, window: .weekly)])
    }

    /// Critério 6: dado com mais de 15 min não avisa, some do estado e volta como nova base
    @Test func staleDataNeverAlertsAndLeavesNoState() {
        var run = AlertRun()
        let stale = read(window(session, 95, resetsAt: minutes(30)), at: minutes(-16))

        #expect(run.step([work], read(window(session, 85, resetsAt: minutes(30)), at: now), at: now).isEmpty)
        #expect(run.step([work], stale, at: now).isEmpty)
        #expect(run.state.isEmpty)
        #expect(run.step([work], read(window(session, 95, resetsAt: minutes(30)), at: now), at: now).isEmpty)
        #expect(run.step([work], read(window(session, 96, resetsAt: minutes(30)), at: minutes(1)), at: minutes(1)).isEmpty)
    }

    /// Critério 6: só erro, sem janelas (token expirado), ou sem leitura nenhuma
    @Test func accountWithAnErrorAndNoDataNeverAlerts() {
        var run = AlertRun()

        #expect(run.step([work], read(window(session, 85, resetsAt: minutes(30)), at: now), at: now).isEmpty)
        #expect(run.step([work], [work.id: Usage(error: "Token expired", updatedAt: now)], at: now).isEmpty)
        #expect(run.state.isEmpty)
        #expect(run.step([work], [:], at: now).isEmpty)
        #expect(run.step([work], read(window(session, 95, resetsAt: minutes(30)), at: now), at: now).isEmpty)
    }

    /// Regra 8: sem horário de reset, avisa em 90% mas uma queda de percentual nunca vira "disponível de novo"
    @Test func windowWithoutResetTimeNeverAnnouncesAvailable() {
        var run = AlertRun()
        let steps = [85.0, 92, 10].map { percent in run.step([work], read(window(.weekly, percent), at: now), at: now) }

        #expect(steps == [[], [.nearLimit(account: work.id, window: .weekly)], []])
    }

    /// QA: depois do reset a API do Claude manda five_hour com resets_at nulo; o reset ainda é anunciado, uma vez só
    @Test func resetIsAnnouncedWhenTheNewReadingHasNoResetTime() {
        var run = AlertRun()
        let available = LimitAlert.availableAgain(account: work.id, window: session)

        #expect(run.step([work], read(window(session, 95, resetsAt: minutes(2)), at: now), at: now).isEmpty)
        #expect(run.step([work], read(window(session, 0), at: minutes(3)), at: minutes(3)) == [available])
        #expect(run.step([work], read(window(session, 0), at: minutes(4)), at: minutes(4)).isEmpty)
        // nova sessão que estoura de novo avisa
        #expect(run.step([work], read(window(session, 92, resetsAt: minutes(300)), at: minutes(5)), at: minutes(5))
            == [.nearLimit(account: work.id, window: session)])
    }

    /// QA: local e API discordam por frações de segundo no horário de reset (00:59:59.9 × 01:00); um aviso só
    @Test func resetTimesThatDifferSlightlyBetweenSourcesAnnounceOnce() {
        var run = AlertRun()
        let api = minutes(3).addingTimeInterval(-0.1)
        let local = minutes(3)
        var alerts: [LimitAlert] = []
        for (step, reset) in [api, local, api, local, api].enumerated() {
            let time = minutes(Double(step))
            alerts += run.step([work], read(window(session, 95, resetsAt: reset), at: time), at: time)
        }

        #expect(alerts == [.availableAgain(account: work.id, window: session)])
    }

    /// QA: local e API discordam do reset por segundos; um refresh nesse intervalo lê a fonte atrasada ainda em 95%.
    /// Não é um período novo: "perto do limite" não se repete antes do "disponível de novo"
    @Test func aRefreshBetweenTwoSourcesResetTimesDoesNotWarnAgain() {
        var run = AlertRun()
        let local = minutes(3)
        let api = local.addingTimeInterval(5)
        let steps: [(percent: Double, resetsAt: Date, at: Date)] = [
            (85, local, now),
            (95, local, minutes(1)),
            (95, api, local.addingTimeInterval(2)),     // dentro da diferença: pela API ainda não resetou
            (95, local, local.addingTimeInterval(62)),  // snapshot local velho, depois dos dois horários
        ]
        var alerts: [LimitAlert] = []
        for step in steps {
            alerts += run.step([work], read(window(session, step.percent, resetsAt: step.resetsAt), at: step.at), at: step.at)
        }

        #expect(alerts == [.nearLimit(account: work.id, window: session), .availableAgain(account: work.id, window: session)])
    }

    /// QA: esconder (sai da lista), cruzar 90% escondida e voltar é nova base silenciosa; reordenar não repete nada
    @Test func hiddenAccountComesBackAsASilentBaselineAndReorderKeepsState() {
        var run = AlertRun()
        func data(work workPercent: Double, codex codexPercent: Double) -> [String: Usage] {
            [
                work.id: Usage(windows: [window(.weekly, workPercent, resetsAt: minutes(600))], updatedAt: now),
                codex.id: Usage(windows: [window(.weekly, codexPercent, resetsAt: minutes(600))], updatedAt: now),
            ]
        }

        #expect(run.step([work, codex], data(work: 85, codex: 85), at: now).isEmpty)
        #expect(run.step([work], data(work: 85, codex: 95), at: now).isEmpty)          // codex escondida
        #expect(run.step([work, codex], data(work: 85, codex: 95), at: now).isEmpty)   // volta já acima: base
        #expect(run.step([codex, work], data(work: 85, codex: 96), at: now).isEmpty)   // reordenada
        // a conta que ficou visível continua com o próprio estado: cruzar agora avisa só ela
        #expect(run.step([codex, work], data(work: 92, codex: 96), at: now) == [.nearLimit(account: work.id, window: .weekly)])
    }

    /// QA: no mesmo passo, um reset e um novo cruzamento acima de 90% da mesma conta: só o aviso de limite
    @Test func aResetAndANewCrossingTogetherSendOnlyTheWarning() {
        var run = AlertRun()
        let first = read(window(session, 95, resetsAt: minutes(2)), window(.weekly, 80, resetsAt: minutes(600)), at: now)
        let later = read(window(session, 3, resetsAt: minutes(300)), window(.weekly, 91, resetsAt: minutes(600)), at: minutes(3))

        #expect(run.step([work], first, at: now).isEmpty)
        #expect(run.step([work], later, at: minutes(3)) == [.nearLimit(account: work.id, window: .weekly)])
    }

    /// Conta removida nos Ajustes e janela que sumiu saem do estado
    @Test func removedAccountsLeaveNoState() {
        var run = AlertRun()
        let both: [String: Usage] = [
            work.id: Usage(windows: [window(session, 50), window(.weekly, 60)], updatedAt: now),
            codex.id: Usage(windows: [window(.weekly, 70)], updatedAt: now),
        ]
        _ = run.step([work, codex], both, at: now)
        _ = run.step([work], [work.id: Usage(windows: [window(.weekly, 60)], updatedAt: now)], at: now)

        #expect(Array(run.state.keys) == [AlertKey(account: work.id, window: .weekly)])
    }
}

/// Clock e caixa de saída falsos para o LimitNotifier
@MainActor
final class FakeNotifications {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var isOn = false
    var posted: [Notice] = []

    func makeNotifier() -> LimitNotifier {
        LimitNotifier(isOn: { self.isOn }, deliver: { self.posted.append($0) }, clock: { self.now })
    }
}

@MainActor
@Suite("Limit notifier")
struct NotifierTests {
    let work = Account(name: "Claude Work", glyph: .claude, provider: .claude(configDir: "/h/.claude-work"))
    let session = WindowKind.session(hours: 5)

    func reading(_ percent: Double, resetsAt: Date?, at time: Date) -> [String: Usage] {
        [work.id: Usage(windows: [window(session, percent, resetsAt: resetsAt)], updatedAt: time)]
    }

    /// Texto do aviso da conta work com uma única janela
    func text(_ alert: LimitAlert, _ limit: LimitWindow) -> Notice? {
        notice(for: alert, accounts: [work], usage: [work.id: Usage(windows: [limit])])
    }

    /// Desligado, o estado anda mesmo assim: ligar depois não repete um cruzamento antigo
    @Test func crossingsWhileOffAreNeverReplayedWhenTurnedOn() {
        let fake = FakeNotifications()
        let notifier = fake.makeNotifier()
        let reset = fake.now.addingTimeInterval(180)

        notifier.update(accounts: [work], usage: reading(85, resetsAt: reset, at: fake.now))
        notifier.update(accounts: [work], usage: reading(92, resetsAt: reset, at: fake.now))
        fake.isOn = true
        notifier.update(accounts: [work], usage: reading(93, resetsAt: reset, at: fake.now))
        #expect(fake.posted.isEmpty)

        fake.now = reset
        notifier.update(accounts: [work], usage: reading(93, resetsAt: reset, at: reset.addingTimeInterval(-60)))
        #expect(fake.posted.map(\.id) == ["\(work.id)#available"])
    }

    @Test func eachAlertPostsOneNoticeWhenOn() {
        let fake = FakeNotifications()
        fake.isOn = true
        let notifier = fake.makeNotifier()

        notifier.update(accounts: [work], usage: reading(85, resetsAt: nil, at: fake.now))
        notifier.update(accounts: [work], usage: reading(92, resetsAt: nil, at: fake.now))
        notifier.update(accounts: [work], usage: reading(95, resetsAt: nil, at: fake.now))

        #expect(fake.posted.map(\.id) == ["\(work.id)#near"])
    }

    // Os textos esperados usam tr(...) para o teste valer em qualquer idioma do sistema

    /// Exemplo do spec: "Claude Work is close to its limit" / "5h session: 92% · resets in 1h20"
    @Test func nearLimitNoticeNamesTheAccountWindowAndReset() {
        let resetsAt = Date().addingTimeInterval(3600 + 20 * 60 + 30)
        let limit = window(session, 92.4, resetsAt: resetsAt)
        let near = text(.nearLimit(account: work.id, window: session), limit)
        let title = tr("Claude Work is close to its limit", "Claude Work está perto do limite", "Claude Work está cerca del límite")

        #expect(near?.id == "\(work.id)#near")
        #expect(near?.title == title)
        #expect(near?.body == "\(limit.label): 92% · \(resetText(resetsAt, countdown: true))")
    }

    @Test func nearLimitNoticeWithoutResetTimeShowsOnlyThePercent() {
        let limit = window(.weekly, 90)
        #expect(text(.nearLimit(account: work.id, window: .weekly), limit)?.body == "\(limit.label): 90%")
    }

    @Test func availableAgainNoticeSaysTheWindowHasReset() {
        let limit = window(.weekly, 97, resetsAt: Date().addingTimeInterval(-60))
        let available = text(.availableAgain(account: work.id, window: .weekly), limit)
        let title = tr("Claude Work is available again", "Claude Work está disponível de novo", "Claude Work vuelve a estar disponible")

        #expect(available?.id == "\(work.id)#available")
        #expect(available?.title == title)
        #expect(available?.body == tr("\(limit.label) has reset", "\(limit.label) resetou", "\(limit.label) se reinició"))
    }
}
