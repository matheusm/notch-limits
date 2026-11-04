import SwiftUI

// Linha de uma conta no painel expandido do notch: anel, nome, etiquetas e uma barra por janela de limite

struct NotchAccountRow: View {
    let account: Account
    let usage: Usage?
    let isBest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RingIcon(
                percent: usage?.peak,
                glyph: account.glyph,
                tint: .white,
                progressTint: usage?.peak.flatMap(alertColor(for:)) ?? Theme.ring,
                size: 34
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(account.name).font(Theme.title)
                    if let plan = usage?.plan, !plan.isEmpty {
                        Tag(plan)
                    }
                    if isBest {
                        // estado, não plano: visual do chip selecionado, sem cor nova (cor só para alerta)
                        Tag(bestNowLabel, filled: true).help(bestNowHelp(account.provider))
                    }
                    Spacer()
                    if let peak = usage?.peak {
                        Text("\(Int(peak.rounded()))%")
                            .font(Theme.figure)
                            .foregroundStyle(alertColor(for: peak) ?? .white)
                    }
                }

                if let at = usage?.updatedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(ageText(at)).font(Theme.caption)
                            .foregroundStyle(usage?.isStale == true ? Theme.warning : Theme.dim)
                    }
                    .padding(.top, -4)
                }

                if let err = usage?.visibleError {
                    WarningLine(err)
                }

                if let usage, !usage.windows.isEmpty {
                    windowRows(usage)
                } else if usage == nil {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

extension NotchAccountRow {
    /// Colunas de largura fixa para as barras alinharem entre contas. O ritmo usa Date() aqui, na borda;
    /// o painel redesenha a cada atualização (60 s), o bastante para um texto com minutos
    private func windowRows(_ usage: Usage) -> some View {
        let now = Date()
        return VStack(spacing: 7) {
            ForEach(usage.windows) { limit in
                let windowPace = pace(of: limit, in: usage, now: now)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text(limit.shortLabel).font(Theme.body).foregroundStyle(Theme.dim)
                            .frame(width: 46, alignment: .leading)
                        UsageBar(percent: limit.percent, expected: windowPace?.expected)
                        Text("\(Int(limit.percent.rounded()))%")
                            .font(Theme.body.weight(.medium).monospacedDigit())
                            .frame(width: 32, alignment: .trailing)
                        Text(resetText(limit.resetsAt, short: true, countdown: limit.isSession))
                            .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.dim)
                            .frame(width: 96, alignment: .trailing)
                    }
                    if let limitAt = windowPace?.limitAt {
                        // a cor que a janela já tem: as palavras são o sinal, nunca uma cor nova
                        Text(paceText(limitAt)).font(Theme.caption)
                            .foregroundStyle(alertColor(for: limit.percent) ?? Theme.dim)
                            .padding(.leading, 56)   // alinhada à borda da barra: rótulo de 46 + espaço de 10
                    }
                }
            }
        }
    }
}

private struct UsageBar: View {
    let percent: Double
    let expected: Double?   // traço do ritmo uniforme; nil sem ritmo

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(alertColor(for: percent) ?? Theme.ring)
                    .frame(width: max(geo.size.width * min(percent, 100) / 100, percent > 0 ? 4 : 0))
            }
            .overlay(alignment: .leading) {
                // overlay: o traço passa da barra de 4 pt sem mudar a altura da linha nem as colunas
                if let expected {
                    Capsule().fill(.white.opacity(0.55))
                        .frame(width: 1.5, height: 8)
                        .offset(x: geo.size.width * min(expected, 100) / 100 - 0.75)
                }
            }
        }
        .frame(height: 4)
        .frame(minWidth: 80, maxWidth: .infinity)
    }
}
