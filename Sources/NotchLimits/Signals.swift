import Foundation

// Sinais calculados sobre o uso para decidir o que fazer agora: "melhor agora" e ritmo

/// "Melhor agora": por provedor, a conta com o menor pico exibido entre as que têm dado útil.
/// Precisa de duas candidatas ou mais (nunca chama de melhor contra uma conta que não dá para ver);
/// empate no menor valor ou todas em 100% não marcam ninguém. Claude e Codex nunca se comparam
func bestAccountIDs(accounts: [Account], usage: [String: Usage], now: Date) -> Set<String> {
    let candidates = accounts.compactMap { account -> (provider: String, id: String, peak: Int)? in
        guard let current = usage[account.id], current.isUsable(at: now), let peak = current.peak else { return nil }
        return (account.provider.name, account.id, Int(peak.rounded()))   // o mesmo número que a linha mostra
    }
    var best: Set<String> = []
    for group in Dictionary(grouping: candidates, by: \.provider).values where group.count >= 2 {
        let ranked = group.sorted { $0.peak < $1.peak }
        guard ranked[0].peak < ranked[1].peak, ranked[0].peak < 100 else { continue }
        best.insert(ranked[0].id)
    }
    return best
}

/// Etiqueta e dica iguais no painel do notch e no menu
let bestNowLabel = tr("Best now", "Melhor agora", "Mejor ahora")

func bestNowHelp(_ provider: Provider) -> String {
    let name = provider.title   // nome do provedor não se traduz
    return tr(
        "Most headroom among your \(name) accounts",
        "Mais folga entre suas contas \(name)",
        "Más margen entre tus cuentas de \(name)"
    )
}

// MARK: - Ritmo

extension LimitWindow {
    /// Tamanho da janela pelo tipo; nil quando é desconhecido (Codex sem window_minutes vira sessão de 0 h)
    var duration: TimeInterval? {
        switch kind {
        case .session(let hours): hours > 0 ? TimeInterval(hours) * 3600 : nil
        case .weekly, .weeklyModel: 7 * 86_400
        case .days(let days): days > 0 ? TimeInterval(days) * 86_400 : nil
        }
    }
}

struct Pace: Equatable {
    let expected: Double   // 0...100: o uso agora se fosse distribuído por igual (o traço na barra)
    let limitAt: Date?     // quando o ritmo atual chega a 100%, só se for antes do reset
}

/// No começo da janela uma rajada só projeta números absurdos: sem projeção antes de 15% dela
let paceMinElapsed = 0.15

/// Projeção linear desde o início da janela (resetsAt − duração), sem histórico.
/// nil sem dado útil, sem tamanho conhecido, sem reset futuro ou se a janela começaria no futuro (tamanho suposto errado)
func pace(of window: LimitWindow, in usage: Usage, now: Date) -> Pace? {
    guard usage.isUsable(at: now), let duration = window.duration, let resetsAt = window.resetsAt, resetsAt > now
    else { return nil }
    let start = resetsAt.addingTimeInterval(-duration)
    guard start <= now else { return nil }
    return Pace(
        expected: now.timeIntervalSince(start) / duration * 100,
        limitAt: projectedLimit(window.percent, from: start, to: resetsAt, observed: usage.updatedAt, now: now)
    )
}

/// Janela de start a resetsAt. O percentual foi medido no snapshot (observed), não agora: a taxa usa esse horário
private func projectedLimit(_ percent: Double, from start: Date, to resetsAt: Date, observed: Date?, now: Date) -> Date? {
    guard let observed, percent > 0, percent < 100 else { return nil }
    let elapsed = observed.timeIntervalSince(start)
    guard elapsed / resetsAt.timeIntervalSince(start) >= paceMinElapsed else { return nil }
    let full = start.addingTimeInterval(elapsed * 100 / percent)
    // depois do reset dá tempo; antes de agora o snapshot está atrasado
    return full > now && full < resetsAt ? full : nil
}

/// "Neste ritmo: limite hoje 16:20", no mesmo formato de dia e hora do reset
func paceText(_ limitAt: Date) -> String {
    let when = dayTimeText(limitAt)
    return tr("At this pace: limit \(when)", "Neste ritmo: limite \(when)", "A este ritmo: límite \(when)")
}
