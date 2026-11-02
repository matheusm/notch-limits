import Foundation

// Sinais calculados sobre o uso para decidir o que fazer agora (R-07 "melhor agora"; o ritmo do R-08 entra aqui)

/// "Melhor agora" (D-016): por provedor, a conta com o menor pico exibido entre as que têm dado útil.
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
