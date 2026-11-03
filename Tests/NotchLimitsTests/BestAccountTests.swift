import Foundation
import Testing
@testable import NotchLimits

@Suite("Best account now")
struct BestAccountTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let personal = Account(name: "Claude", glyph: .claude, provider: .claude(configDir: "/h/.claude"))
    let work = Account(name: "Claude Work", glyph: .claude, provider: .claude(configDir: "/h/.claude-work"))
    let team = Account(name: "Claude Team", glyph: .claude, provider: .claude(configDir: "/h/.claude-team"))
    let codex = Account(name: "Codex", glyph: .codex, provider: .codex(home: "/h/.codex"))
    let codexTeam = Account(name: "Codex Team", glyph: .codex, provider: .codex(home: "/h/.codex-team"))

    /// Lido há 1 min: dado útil
    func fresh(_ percent: Double) -> Usage { usage(minutesAgo: 1, percent: percent, now: now) }

    /// Lido há 16 min: velho demais para a UI mostrar sem aviso
    func stale(_ percent: Double) -> Usage { usage(minutesAgo: 16, percent: percent, now: now) }

    func best(_ accounts: [Account], _ usage: [String: Usage]) -> Set<String> {
        bestAccountIDs(accounts: accounts, usage: usage, now: now)
    }

    /// Critério 1
    @Test func marksTheAccountWithTheMostHeadroom() {
        #expect(best([personal, work], [personal.id: fresh(60), work.id: fresh(30)]) == [work.id])
    }

    /// Critério 2: nunca compara Claude com Codex
    @Test func singleAccountProviderHasNoMarker() {
        #expect(best([personal, codex], [personal.id: fresh(30), codex.id: fresh(60)]).isEmpty)
        #expect(best([personal], [personal.id: fresh(30)]).isEmpty)
    }

    /// Critério 3
    @Test func providersAreRankedSeparately() {
        let data = [personal.id: fresh(30), work.id: fresh(60), codex.id: fresh(80), codexTeam.id: fresh(50)]

        #expect(best([personal, work, codex, codexTeam], data) == [personal.id, codexTeam.id])
    }

    /// Critério 4: compara o número que a linha mostra (12.4 e 12.2 aparecem como 12%)
    @Test func peaksThatDisplayTheSameAreATie() {
        #expect(best([personal, work], [personal.id: fresh(12.4), work.id: fresh(12.2)]).isEmpty)
        #expect(best([personal, work, team], [personal.id: fresh(20), work.id: fresh(20), team.id: fresh(50)]).isEmpty)
        #expect(best([personal, work], [personal.id: fresh(12.4), work.id: fresh(12.6)]) == [personal.id])
    }

    /// Critério 5: a conta velha em 5% ganharia se contasse
    @Test func staleEmptyOrErrorOnlyAccountsAreNotCandidates() {
        let missing = Account(name: "Claude New", glyph: .claude, provider: .claude(configDir: "/h/.claude-new"))
        let data = [
            personal.id: fresh(50),
            work.id: fresh(70),
            team.id: stale(5),
            codex.id: Usage(updatedAt: now),
            codexTeam.id: Usage(error: "Token expired"),
        ]

        #expect(best([personal, work, team, missing, codex, codexTeam], data) == [personal.id])
    }

    /// Critério 5: nunca chama de melhor uma conta comparada com outra que não dá para ver
    @Test func oneCandidateLeftMeansNoMarker() {
        let data = [personal.id: fresh(50), work.id: stale(5), team.id: Usage(error: "Token expired")]

        #expect(best([personal, work, team], data).isEmpty)
    }

    /// Critério 6: um 429 em segundo plano com o snapshot local fresco não tira a conta da disputa
    @Test func freshDataWithABackgroundErrorStillCounts() {
        var limited = fresh(20)
        limited.error = "API rate limited"

        #expect(best([personal, work], [personal.id: fresh(40), work.id: limited]) == [work.id])
    }

    /// QA: só as contas visíveis disputam (o Store passa só elas); uso de uma conta escondida no dicionário não conta.
    /// Arredondamento igual ao da linha: 12.5 aparece como 13%, então 12.4 (12%) é a melhor
    @Test func onlyShownAccountsCompeteAndHalfPercentsRoundLikeTheRow() {
        let data = [personal.id: fresh(50), work.id: fresh(60), team.id: fresh(5)]

        #expect(best([personal, work], data) == [personal.id])
        #expect(best([personal, work], [personal.id: fresh(12.5), work.id: fresh(12.4)]) == [work.id])
        #expect(best([personal, work], [personal.id: usage(minutesAgo: 15, percent: 10, now: now), work.id: fresh(20)]) == [personal.id])
    }

    /// Critério 7: 99.6% aparece como 100%, então também conta como esgotada
    @Test func exhaustedAccountsAreNeverBest() {
        #expect(best([personal, work], [personal.id: fresh(100), work.id: fresh(104)]).isEmpty)
        #expect(best([personal, work], [personal.id: fresh(99.6), work.id: fresh(104)]).isEmpty)
        #expect(best([personal, work], [personal.id: fresh(99.4), work.id: fresh(104)]) == [personal.id])
    }
}
