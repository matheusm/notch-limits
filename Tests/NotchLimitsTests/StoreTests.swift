import Foundation
import Testing
@testable import NotchLimits

/// Conta quantas vezes a API foi chamada (as chamadas rodam fora do main actor)
final class APICalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func hit() { lock.withLock { count += 1 } }
}

/// Guarda cada relatório do Store ao notificador: ids das contas e o pico de cada uso
@MainActor
final class Reports {
    var calls: [(accounts: [String], peaks: [String: Double?])] = []
}

/// Segura uma chamada à API até o teste liberar
final class Gate: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

    func wait() async {
        for await _ in stream {}
    }

    func open() { continuation.finish() }
}

@MainActor
@Suite("Modo híbrido: local primeiro, API só quando velho")
struct StoreTests {
    let account = Account(name: "A", glyph: .claude, provider: .claude(configDir: "/x"))
    let other = Account(name: "B", glyph: .codex, provider: .codex(home: "/y"))
    let calls = APICalls()

    func makeStore(local: Usage?, remote: @escaping () throws -> Usage = { usage(minutesAgo: 0, percent: 50) }) -> Store {
        makeStore(accounts: [account], local: { _ in local }, remote: { _ in try remote() })
    }

    func makeStore(accounts: [Account],
                   local: @escaping (Account) -> Usage?,
                   remote: @escaping (Account) async throws -> Usage = { _ in usage(minutesAgo: 0, percent: 50) },
                   onRefresh: @escaping @MainActor ([Account], [String: Usage]) -> Void = { _, _ in }) -> Store {
        let calls = calls
        return Store(
            accounts: accounts,
            local: local,
            remote: { acc in
                calls.hit()
                return try await remote(acc)
            },
            onRefresh: onRefresh,
            autoRefresh: false
        )
    }

    @Test func freshLocalSnapshotSkipsTheAPI() async {
        let store = makeStore(local: usage(minutesAgo: 9, percent: 20))
        await store.refresh()

        #expect(calls.value == 0)
        #expect(store.usage[account.id]?.peak == 20)
    }

    @Test func staleLocalSnapshotCallsTheAPI() async {
        let store = makeStore(local: usage(minutesAgo: 11, percent: 20))
        await store.refresh()

        #expect(calls.value == 1)
        #expect(store.usage[account.id]?.peak == 50)
    }

    /// Abrir o notch/menu chama refresh(network: false)
    @Test func openingThePanelNeverCallsTheAPI() async {
        let store = makeStore(local: usage(minutesAgo: 60, percent: 20))
        await store.refresh(network: false)

        #expect(calls.value == 0)
        #expect(store.usage[account.id]?.peak == 20)
    }

    @Test func refreshButtonForcesTheAPI() async {
        let store = makeStore(local: usage(minutesAgo: 1, percent: 20))
        await store.refresh(force: true)

        #expect(calls.value == 1)
    }

    @Test func rateLimitKeepsLastDataAndBacksOff() async {
        let store = makeStore(local: usage(minutesAgo: 11, percent: 20)) {
            throw UsageError("rate limited", retryAfter: 300)
        }
        await store.refresh()
        await store.refresh(force: true)

        #expect(calls.value == 1)                               // segunda tentativa bloqueada pelo Retry-After
        #expect(store.usage[account.id]?.peak == 20)            // continua mostrando o snapshot local
        #expect(store.usage[account.id]?.visibleError == nil)   // dado ainda útil: sem aviso
    }

    @Test func failureWithoutAnyDataShowsTheError() async {
        let store = makeStore(local: nil) { throw UsageError("Token expired") }
        await store.refresh()

        #expect(store.usage[account.id]?.windows.isEmpty == true)
        #expect(store.usage[account.id]?.visibleError == "Token expired")
    }

    /// O notificador recebe o uso final uma vez por atualização, não uma vez por conta
    @Test func refreshReportsTheFinalUsageOnce() async {
        let other = other
        let reports = Reports()
        let store = makeStore(accounts: [account, other]) { acc in
            acc.id == other.id ? usage(minutesAgo: 1, percent: 30) : usage(minutesAgo: 11, percent: 20)
        } onRefresh: { accounts, usage in
            reports.calls.append((accounts.map(\.id), usage.mapValues(\.peak)))
        }

        await store.refresh()
        #expect(reports.calls.count == 1)
        #expect(reports.calls.first?.accounts == [account.id, other.id])
        #expect(reports.calls.first?.peaks == [account.id: 50, other.id: 30])   // a API já respondeu para a conta velha

        await store.refresh(network: false)
        #expect(reports.calls.count == 2)
    }

    // MARK: - Contas ao vivo (Ajustes)

    /// Critério 5: mostrar uma conta nos Ajustes lê o disco na hora, mesmo com dado velho, sem chamar a API
    @Test func settingAccountsLoadsNewOnesFromDiskWithoutTheAPI() async {
        let other = other
        let store = makeStore(accounts: [account]) { acc in
            acc.id == other.id ? usage(minutesAgo: 60, percent: 30) : usage(minutesAgo: 1, percent: 20)
        }
        await store.refresh()

        var hidden = account
        hidden.enabled = false
        await store.setAccounts([hidden, other]).value

        #expect(calls.value == 0)
        #expect(store.accounts.map(\.id) == [other.id])   // o Store só recebe as visíveis
        #expect(store.usage[other.id]?.peak == 30)
    }

    @Test func settingAccountsDropsRemovedAccountsData() async {
        let other = other
        let store = makeStore(accounts: [account, other]) { _ in
            usage(minutesAgo: 11, percent: 20)
        } remote: { acc in
            guard acc.id == other.id else { return usage(minutesAgo: 0, percent: 50) }
            throw UsageError("rate limited", retryAfter: 300)
        }
        await store.refresh()
        #expect(calls.value == 2)

        await store.setAccounts([account]).value

        #expect(store.usage[other.id] == nil)
        #expect(store.usage[account.id]?.peak == 50)
        // o uso some, mas o Retry-After continua valendo quando ela volta
        await store.setAccounts([account, other]).value
        await store.refresh(force: true)
        #expect(calls.value == 3)
    }

    /// Esconder e mostrar de novo nos Ajustes não fura o Retry-After
    @Test func hidingAndShowingAnAccountKeepsItsBackoff() async {
        let store = makeStore(local: usage(minutesAgo: 11, percent: 20)) {
            throw UsageError("rate limited", retryAfter: 300)
        }
        await store.refresh()

        var hidden = account
        hidden.enabled = false
        await store.setAccounts([hidden]).value
        await store.setAccounts([account]).value
        await store.refresh()
        await store.refresh(force: true)

        #expect(calls.value == 1)
        #expect(store.usage[account.id]?.peak == 20)
    }

    /// Um 429 que chega com a conta escondida ainda vale quando ela volta
    @Test func aRateLimitThatArrivesWhileHiddenStillBacksOff() async {
        let gate = Gate()
        let store = makeStore(accounts: [account]) { _ in
            usage(minutesAgo: 11, percent: 20)
        } remote: { _ in
            await gate.wait()
            throw UsageError("rate limited", retryAfter: 300)
        }

        let refreshing = Task { await store.refresh() }
        while !store.loading { await Task.yield() }
        await store.setAccounts([]).value
        gate.open()
        await refreshing.value
        await store.setAccounts([account]).value
        await store.refresh(force: true)

        #expect(calls.value == 1)
        #expect(store.usage[account.id]?.peak == 20)
    }

    /// Critério 7: ids provider:path; reordenar ou renomear não troca o uso nem o backoff de conta
    @Test func reorderingKeepsEachAccountsUsageAndBackoff() async {
        let other = other
        let store = makeStore(accounts: [account, other]) { acc in
            acc.id == other.id ? usage(minutesAgo: 11, percent: 30) : usage(minutesAgo: 1, percent: 20)
        } remote: { acc in
            guard acc.id == other.id else { return usage(minutesAgo: 0, percent: 50) }
            throw UsageError("rate limited", retryAfter: 300)
        }
        await store.refresh()
        #expect(calls.value == 1)   // só a conta com dado velho, que leva 429

        var renamed = other
        renamed.name = "B renamed"
        await store.setAccounts([renamed, account]).value
        await store.refresh(force: true)

        #expect(store.accounts.map(\.name) == ["B renamed", "A"])
        #expect(calls.value == 2)                           // a conta em backoff continua bloqueada
        #expect(store.usage[other.id]?.peak == 30)
        #expect(store.usage[account.id]?.peak == 50)
    }

    /// Uma mudança feita durante uma atualização vale quando ela termina: a conta removida não volta
    @Test func accountsChangedDuringARefreshApplyWhenItEnds() async {
        let other = other
        let gate = Gate()
        let store = makeStore(accounts: [account]) { acc in
            acc.id == other.id ? usage(minutesAgo: 1, percent: 30) : usage(minutesAgo: 11, percent: 20)
        } remote: { _ in
            await gate.wait()
            return usage(minutesAgo: 0, percent: 50)
        }

        let refreshing = Task { await store.refresh() }
        while !store.loading { await Task.yield() }
        await store.setAccounts([other]).value
        gate.open()
        await refreshing.value

        #expect(calls.value == 1)
        #expect(store.usage[account.id] == nil)
        #expect(store.usage[other.id]?.peak == 30)
    }
}

@Suite("Usage")
struct UsageTests {
    @Test func newestPrefersMostRecentNonEmptySnapshot() {
        let old = usage(minutesAgo: 30, percent: 1)
        let recent = usage(minutesAgo: 2, percent: 2)
        let empty = Usage(updatedAt: Date())

        #expect(Usage.newest(old, recent)?.peak == 2)
        #expect(Usage.newest(recent, old)?.peak == 2)
        #expect(Usage.newest(empty, old)?.peak == 1)
        #expect(Usage.newest(nil, nil) == nil)
    }

    @Test func errorIsOnlyVisibleWithoutUsefulData() {
        var fresh = usage(minutesAgo: 5)
        fresh.error = "x"
        var stale = usage(minutesAgo: 16)
        stale.error = "x"

        #expect(fresh.visibleError == nil)
        #expect(stale.isStale && stale.visibleError == "x")
        #expect(Usage(error: "x").visibleError == "x")
    }

    /// O relógio é injetado; com exatamente 15 min ainda vale, sem janelas ou sem data não vale
    @Test func usableMeansWindowsAndAtMostFifteenMinutesOld() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let read = { (minutesAgo: Double) in Usage(windows: [window(.weekly)], updatedAt: now.addingTimeInterval(-minutesAgo * 60)) }

        #expect(read(15).isUsable(at: now))
        #expect(!read(15).isStale(at: now))
        #expect(!read(15.1).isUsable(at: now))
        #expect(read(15.1).isStale(at: now))
        #expect(!Usage(updatedAt: now).isUsable(at: now))
        #expect(!Usage(windows: [window(.weekly)]).isUsable(at: now))
    }
}
