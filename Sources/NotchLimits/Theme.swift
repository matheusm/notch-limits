import SwiftUI

// Linguagem visual do app (DESIGN.md › App). O painel do notch é a referência: toda superfície usa estes tokens
// e componentes, nunca o estilo padrão do sistema (Form, switch, picker e campo com borda, modo claro), D-023

enum Theme {
    // MARK: Cores: só neutros; cor aparece só como estado (alertColor, 70/90%)

    static let ground = Color.black                    // fundo de toda superfície
    static let ring = Color(white: 0.82)               // anéis e barras no estado normal
    static let dim = Color.white.opacity(0.45)         // texto secundário, chip desligado
    static let separator = Color.white.opacity(0.08)   // linha entre contas
    static let track = Color.white.opacity(0.1)        // trilho das barras
    static let fill = Color.white.opacity(0.06)        // chip desligado, campo em edição
    static let fillOn = Color.white.opacity(0.14)      // chip ligado, etiqueta "Melhor agora"
    static let iconFill = Color.white.opacity(0.08)    // círculo dos botões de ícone
    static let iconInk = Color.white.opacity(0.8)
    static let warning = Color.orange                  // ≥ 70%, dado velho, erros
    static let critical = Color.red                    // ≥ 90%

    /// Largura do painel expandido; os Ajustes usam a mesma para se lerem como parte dele
    static let panelWidth: CGFloat = 380

    // MARK: Tipos

    static let figure = Font.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()   // pico da conta
    static let title = Font.system(size: 13, weight: .semibold)     // nome da conta, título da janela
    static let body = Font.system(size: 11)                          // rótulos e % das janelas
    static let caption = Font.system(size: 10)                       // idade, reset, ritmo, erros, legendas
    static let control = Font.system(size: 10, weight: .medium)      // texto dos chips
    static let icon = Font.system(size: 10, weight: .semibold)       // símbolo dos botões de ícone
    static let label = Font.system(size: 9, weight: .semibold)       // plano e seção, em maiúsculas
}

/// Liga/desliga em forma de cápsula: ✓ ligado, círculo tracejado desligado. Desabilitado fica mais apagado e não clica
struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, on: Bool, action: @escaping () -> Void) {
        self.title = title
        self.on = on
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: on ? "checkmark" : "circle.dashed")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)   // o estado vai no traço de botão selecionado
                Text(title)
            }
            .font(Theme.control)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(on ? Theme.fillOn : Theme.fill, in: Capsule())
            .foregroundStyle(on ? .white : Theme.dim)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Símbolo num círculo; o rótulo vira acessibilidade e dica
struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .accessibilityLabel(label)
                .iconFace()
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.iconInk)
        .help(label)
    }
}

extension View {
    /// Face do botão de ícone, também usada como rótulo de menu (ícone da conta nos Ajustes)
    func iconFace(width: CGFloat = 22, height: CGFloat = 20) -> some View {
        font(Theme.icon)
            .frame(width: width, height: height)
            .background(Theme.iconFill, in: Circle())
    }

    /// Linha secundária apagada: idade, caminho, legendas
    func secondaryText() -> some View {
        font(Theme.caption).foregroundStyle(Theme.dim)
    }
}

/// Etiqueta curta em maiúsculas: plano da conta e título de seção; filled é o "Melhor agora" (estado, sem cor nova)
struct Tag: View {
    let text: String
    var filled = false

    init(_ text: String, filled: Bool = false) {
        self.text = text
        self.filled = filled
    }

    var body: some View {
        if filled {
            label.foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.fillOn, in: Capsule())
        } else {
            label.foregroundStyle(Theme.dim)
        }
    }

    private var label: some View {
        Text(text.uppercased()).font(Theme.label).tracking(0.5)
    }
}

/// Linha entre contas
struct Separator: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1)
    }
}

/// Erro em uma linha, na cor de aviso, como o painel mostra
struct WarningLine: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.caption).foregroundStyle(Theme.warning)
    }
}
