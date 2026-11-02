import SwiftUI

// Ícones da barra: anel de progresso com o logo no meio, renderizados como template (branco/preto conforme o tema)

enum Glyph {
    case claude, codex
    case symbol(String)
}

/// Starburst do Claude: raios em cápsula alternando comprimento
struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let w = r * 0.26
        var p = Path()
        for i in 0..<12 {
            let len = r * (i % 2 == 0 ? 1.0 : 0.78)
            let ray = Path(roundedRect: CGRect(x: -w / 2, y: -len, width: w, height: len), cornerRadius: w / 2)
            let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: Double(i) / 12 * 2 * .pi + 0.13)
            p.addPath(ray, transform: t)
        }
        return p
    }
}

/// Flor da OpenAI simplificada: 6 pétalas entrelaçadas
struct CodexMark: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<6 {
            let petal = Path(roundedRect: CGRect(x: -r * 0.05, y: -r * 0.95, width: r * 0.5, height: r * 0.9),
                             cornerRadius: r * 0.25)
            let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: Double(i) / 6 * 2 * .pi)
            p.addPath(petal, transform: t)
        }
        return p
    }
}

struct RingIcon: View {
    let percent: Double?
    let glyph: Glyph
    var tint: Color = .black            // anel e logo (preto = template na barra)
    var progressTint: Color? = nil      // cor do progresso, padrão = tint
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
            mark.opacity(percent == nil ? 0.4 : 1)
        }
        .frame(width: size, height: size)
        .padding(size / 16)
    }

    @ViewBuilder private var mark: some View {
        switch glyph {
        case .claude: ClaudeMark().fill(tint).frame(width: size * 0.56, height: size * 0.56)
        case .codex: CodexMark().stroke(tint, lineWidth: size / 18).frame(width: size * 0.56, height: size * 0.56)
        case .symbol(let name): Image(systemName: name).font(.system(size: size / 2, weight: .semibold)).foregroundStyle(tint)
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
