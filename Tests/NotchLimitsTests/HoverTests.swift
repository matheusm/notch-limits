import Foundation
import Testing
@testable import NotchLimits

/// Critério 13 do R-05 (D-023): abrir os Ajustes pela engrenagem recolhe o notch, que só expande de novo
/// depois que o ponteiro sai da área e volta
@Suite("Notch hover")
struct HoverTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Passos do timer de 0,1 s com o ponteiro dentro ou fora da área; devolve o horário depois do último passo
    @discardableResult
    func move(_ hover: inout HoverState, inside: Bool, for seconds: Double, from time: Date) -> Date {
        var now = time
        for _ in 0..<Int((seconds * 10).rounded()) {
            hover.update(inside: inside, now: now)
            now += 0.1
        }
        return now
    }

    func expanded(from time: Date) -> (HoverState, Date) {
        var hover = HoverState()
        let now = move(&hover, inside: true, for: 0.5, from: time)
        return (hover, now)
    }

    @Test func pointerRestingInsideExpandsOnlyAfterTheDelay() {
        var hover = HoverState()
        move(&hover, inside: true, for: 0.2, from: start)
        #expect(!hover.expanded)   // só passando a caminho do menu
        move(&hover, inside: true, for: 0.2, from: start + 0.2)
        #expect(hover.expanded)
    }

    @Test func pointerLeavingCollapsesAfterTheDelay() {
        var (hover, now) = expanded(from: start)
        now = move(&hover, inside: false, for: 0.2, from: now)
        #expect(hover.expanded)
        move(&hover, inside: false, for: 0.3, from: now)
        #expect(!hover.expanded)
    }

    @Test func openingSettingsCollapsesAtOnce() {
        var (hover, _) = expanded(from: start)
        hover.dismiss()
        #expect(!hover.expanded)
    }

    @Test func pointerThatStaysInsideAfterOpeningSettingsKeepsItCollapsed() {
        var (hover, now) = expanded(from: start)
        hover.dismiss()
        move(&hover, inside: true, for: 3, from: now)
        #expect(!hover.expanded)
    }

    @Test func leavingAndComingBackAfterOpeningSettingsExpandsAfterTheUsualDelay() {
        var (hover, now) = expanded(from: start)
        hover.dismiss()
        now = move(&hover, inside: true, for: 1, from: now)
        now = move(&hover, inside: false, for: 0.1, from: now)
        now = move(&hover, inside: true, for: 0.2, from: now)
        #expect(!hover.expanded)
        move(&hover, inside: true, for: 0.2, from: now)
        #expect(hover.expanded)
    }

    /// O caso real: recolhido, o controller mede só o notch e as orelhas, e a engrenagem fica abaixo deles, então o
    /// ponteiro parado nela já conta como fora; voltar ao notch expande com o atraso de sempre, nunca na hora
    @Test func pointerRestingAtTheGearStaysCollapsedAndReturningExpandsAfterTheDelay() {
        var (hover, now) = expanded(from: start)
        hover.dismiss()
        now = move(&hover, inside: false, for: 2, from: now)
        #expect(!hover.expanded)
        now = move(&hover, inside: true, for: 0.2, from: now)
        #expect(!hover.expanded)
        move(&hover, inside: true, for: 0.2, from: now)
        #expect(hover.expanded)
    }

    /// Sem tela com notch (ou chip Notch desligado) o painel só recolhe, sem segurar: ao voltar, abre com o atraso normal
    @Test func collapsingWithoutANotchDoesNotHoldItClosed() {
        var (hover, now) = expanded(from: start)
        hover.collapse()
        #expect(!hover.expanded)
        now = move(&hover, inside: true, for: 0.2, from: now)
        #expect(!hover.expanded)
        move(&hover, inside: true, for: 0.2, from: now)
        #expect(hover.expanded)
    }
}
