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

@MainActor
@Suite("Modo híbrido: local primeiro, API só quando velho")
struct StoreTests {
    let account = Account(id: "a", name: "A", glyph: .claude, provider: .claude(configDir: "/x"))
    let calls = APICalls()

    func store(local: Usage?, remote: @escaping () throws -> Usage = { usage(minutesAgo: 0, percent: 50) }) -> Store {
        let calls = calls
        return Store(accounts: [account], local: { _ in local }, remote: { _ in
            calls.hit()
            return try remote()
        }, autoRefresh: false)
    }

    @Test func freshLocalSnapshotSkipsTheAPI() async {
        let s = store(local: usage(minutesAgo: 9, percent: 20))
        await s.refresh()

        #expect(calls.value == 0)
        #expect(s.usage["a"]?.peak == 20)
    }

    @Test func staleLocalSnapshotCallsTheAPI() async {
        let s = store(local: usage(minutesAgo: 11, percent: 20))
        await s.refresh()

        #expect(calls.value == 1)
        #expect(s.usage["a"]?.peak == 50)
    }

    /// Abrir o notch/menu chama refresh(network: false)
    @Test func openingThePanelNeverCallsTheAPI() async {
        let s = store(local: usage(minutesAgo: 60, percent: 20))
        await s.refresh(network: false)

        #expect(calls.value == 0)
        #expect(s.usage["a"]?.peak == 20)
    }

    @Test func refreshButtonForcesTheAPI() async {
        let s = store(local: usage(minutesAgo: 1, percent: 20))
        await s.refresh(force: true)

        #expect(calls.value == 1)
    }

    @Test func rateLimitKeepsLastDataAndBacksOff() async {
        let s = store(local: usage(minutesAgo: 11, percent: 20)) {
            throw UsageError("rate limited", retryAfter: 300)
        }
        await s.refresh()
        await s.refresh(force: true)

        #expect(calls.value == 1)                   // segunda tentativa bloqueada pelo Retry-After
        #expect(s.usage["a"]?.peak == 20)            // continua mostrando o snapshot local
        #expect(s.usage["a"]?.visibleError == nil)   // dado ainda útil: sem aviso
    }

    @Test func failureWithoutAnyDataShowsTheError() async {
        let s = store(local: nil) { throw UsageError("Token expired") }
        await s.refresh()

        #expect(s.usage["a"]?.windows.isEmpty == true)
        #expect(s.usage["a"]?.visibleError == "Token expired")
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
}
