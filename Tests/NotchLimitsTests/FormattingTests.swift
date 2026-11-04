import Foundation
import Testing
@testable import NotchLimits

// Os textos esperados usam tr(...) para o teste valer em qualquer idioma do sistema
@Suite("Textos de reset")
struct FormattingTests {
    @Test func countdownForSessionWindows() {
        let in2h10 = Date().addingTimeInterval(2 * 3600 + 10 * 60 + 30)
        let in45min = Date().addingTimeInterval(45 * 60 + 30)

        #expect(resetText(in2h10, short: true, countdown: true) == tr("in 2h10", "em 2h10", "en 2h10"))
        #expect(resetText(in45min, countdown: true) == tr("resets in 45min", "reseta em 45min", "se reinicia en 45min"))
    }

    @Test func pastOrMissingReset() {
        #expect(resetText(nil).isEmpty)
        #expect(resetText(Date().addingTimeInterval(-60), short: true) == tr("reset", "resetou", "reiniciado"))
    }

    @Test func absoluteResetUsesTomorrowAndRoundsToTheMinute() throws {
        let cal = Calendar.current
        let tomorrow = try #require(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())))
        let at11 = try #require(cal.date(bySettingHour: 11, minute: 0, second: 0, of: tomorrow))

        let text = resetText(at11, short: true)
        #expect(text.hasPrefix(tr("tomorrow", "amanhã", "mañana") + " "))
        // a API manda 10:59:59.9 para resets "às 11:00"
        #expect(resetText(at11.addingTimeInterval(-0.1), short: true) == text)
    }

    /// A linha do ritmo usa o mesmo dia e hora do reset ("amanhã 11:00"), extraído em dayTimeText
    @Test func paceLineUsesTheResetDayAndTimeFormat() throws {
        let cal = Calendar.current
        let tomorrow = try #require(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())))
        let at11 = try #require(cal.date(bySettingHour: 11, minute: 0, second: 0, of: tomorrow))

        #expect(dayTimeText(at11) == resetText(at11, short: true))
        #expect(resetText(at11) == tr("resets \(dayTimeText(at11))", "reseta \(dayTimeText(at11))", "se reinicia \(dayTimeText(at11))"))
        #expect(paceText(at11) == tr("At this pace: limit ", "Neste ritmo: limite ", "A este ritmo: límite ") + dayTimeText(at11))
    }

    @Test(arguments: [
        (WindowKind.session(hours: 5), true, "5h"),
        (.weeklyModel("Fable"), false, "Fable"),
        (.days(2), false, "2d"),
    ])
    func windowKindDrivesCountdownAndShortLabel(kind: WindowKind, isSession: Bool, short: String) {
        #expect(window(kind).isSession == isSession)
        #expect(window(kind).shortLabel == short)
    }
}
