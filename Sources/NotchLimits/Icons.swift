import SwiftUI

// Ícones da barra: anel de progresso com o logo no meio, renderizados como template (branco/preto conforme o tema)

enum Glyph {
    case claude, codex
    case symbol(String)

    /// Valor de "icon" no accounts.json: "claude", "codex" ou um SF Symbol
    init(name: String) {
        switch name {
        case "claude": self = .claude
        case "codex": self = .codex
        default: self = .symbol(name)
        }
    }

    var name: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .symbol(let symbol): symbol
        }
    }
}

/// Starburst do Claude: raios em cápsula alternando comprimento
struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let width = radius * 0.26
        var path = Path()
        for index in 0..<12 {
            let length = radius * (index.isMultiple(of: 2) ? 1.0 : 0.78)
            let ray = Path(roundedRect: CGRect(x: -width / 2, y: -length, width: width, height: length), cornerRadius: width / 2)
            let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: Double(index) / 12 * 2 * .pi + 0.13)
            path.addPath(ray, transform: transform)
        }
        return path
    }
}

/// Flor da OpenAI simplificada: 6 pétalas entrelaçadas
struct CodexMark: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<6 {
            let petal = Path(
                roundedRect: CGRect(x: -radius * 0.05, y: -radius * 0.95, width: radius * 0.5, height: radius * 0.9),
                cornerRadius: radius * 0.25
            )
            let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: Double(index) / 6 * 2 * .pi)
            path.addPath(petal, transform: transform)
        }
        return path
    }
}

struct RingIcon: View {
    let percent: Double?
    let glyph: Glyph
    var tint: Color = .black            // anel e logo (preto = template na barra)
    var progressTint: Color?            // cor do progresso, padrão = tint
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.3), lineWidth: size / 8)
            if let percent, percent > 0 {
                Circle()
                    .trim(from: 0, to: max(min(percent, 100), 3) / 100)
                    .stroke(progressTint ?? tint, style: StrokeStyle(lineWidth: size / 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            GlyphMark(glyph: glyph, tint: tint, size: size).opacity(percent == nil ? 0.4 : 1)
        }
        .frame(width: size, height: size)
        .padding(size / 16)
    }
}

/// Logo do meio do anel, na proporção de um anel de `size`; também aparece sozinho no botão de ícone dos Ajustes
struct GlyphMark: View {
    let glyph: Glyph
    let tint: Color
    let size: CGFloat

    var body: some View {
        switch glyph {
        case .claude: ClaudeMark().fill(tint).frame(width: size * 0.56, height: size * 0.56)
        case .codex: CodexMark().stroke(tint, lineWidth: size / 18).frame(width: size * 0.56, height: size * 0.56)
        case .symbol(let name):
            // decorativo: o nome da conta acompanha o anel
            Image(systemName: name)
                .font(.system(size: size / 2, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        }
    }
}

struct RingStrip: View {
    let items: [(percent: Double?, glyph: Glyph)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { RingIcon(percent: items[$0].percent, glyph: items[$0].glyph) }
        }
    }
}

@MainActor
func renderStrip(_ items: [(percent: Double?, glyph: Glyph)], scale: CGFloat = 2) -> NSImage {
    let renderer = ImageRenderer(content: RingStrip(items: items))
    renderer.scale = scale
    let image = renderer.nsImage ?? NSImage()
    image.isTemplate = true
    return image
}
