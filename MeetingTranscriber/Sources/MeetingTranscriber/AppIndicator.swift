import AppKit
import SwiftUI

/// O que o logo do app sinaliza, na barra de menu e no cabeçalho do popover.
/// Erro ganha um selo vermelho no próprio logo: o alerta precisa ser visto em
/// call e em compartilhamento de tela, quando a notificação costuma ficar
/// suprimida, e não pode ser confundido com o vermelho de "gravando".
enum AppIndicator: Equatable {
    case idle
    case recording
    /// Sistema parado, ou job com captura parcial/falho ainda não visto: selo âmbar.
    case attention
    case error

    static func make(
        status: RecordingStatus,
        micState: MicCaptureState,
        systemNeedsAttention: Bool = false,
        unseenJobProblem: Bool = false
    ) -> AppIndicator {
        switch status {
        case .error:
            return .error
        case .recording:
            if micState.needsAttention { return .error }
            return systemNeedsAttention ? .attention : .recording
        case .idle, .starting, .stopping, .importing:
            // Job falho ou com captura parcial: selo até abrir a lista, para o
            // aviso não depender de notificação (suprimida em tela compartilhada).
            return unseenJobProblem ? .attention : .idle
        }
    }
}

enum AppIndicatorImage {
    static let logoSymbol = "mic.circle"
    static let errorBadgeSymbol = "exclamationmark.circle.fill"
    /// 2.0: pergunta pendente da assistência Teams (azul, forma distinta do erro).
    static let questionBadgeSymbol = "questionmark.circle.fill"

    /// Logo do app com selo vermelho no canto superior direito. Não é template: o
    /// vermelho precisa sobreviver na barra de menu. O glifo usa `labelColor`,
    /// resolvido na hora do desenho, então acompanha o tema claro/escuro.
    static func logoWithErrorBadge(
        size: CGFloat = 18,
        color: NSColor = .systemRed,
        badgeSymbol: String = errorBadgeSymbol,
        accessibility: String = "Meeting Transcriber com erro"
    ) -> NSImage {
        badged(base: logoSymbol, baseColor: .labelColor, badge: badgeSymbol, badgeColor: color, size: size, accessibility: accessibility)
    }

    /// Gravando com pergunta de fim pendente: o ponto vermelho continua visível.
    static func recordingWithQuestionBadge(size: CGFloat = 18) -> NSImage {
        badged(
            base: "record.circle.fill", baseColor: .systemRed,
            badge: questionBadgeSymbol, badgeColor: .systemBlue, size: size,
            accessibility: "Meeting Transcriber gravando, pergunta de encerramento pendente"
        )
    }

    private static func badged(
        base: String, baseColor: NSColor, badge badgeSymbol: String, badgeColor color: NSColor,
        size: CGFloat, accessibility: String
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let logoConfig = NSImage.SymbolConfiguration(pointSize: size * 0.78, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [baseColor]))
            if let logo = NSImage(systemSymbolName: base, accessibilityDescription: nil)?
                .withSymbolConfiguration(logoConfig) {
                let logoSize = logo.size
                logo.draw(in: NSRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: min(logoSize.width, rect.width * 0.86),
                    height: min(logoSize.height, rect.height * 0.86)
                ))
            }
            let badgeSide = size * 0.56
            let badgeRect = NSRect(x: rect.maxX - badgeSide, y: rect.maxY - badgeSide, width: badgeSide, height: badgeSide)
            let badgeConfig = NSImage.SymbolConfiguration(pointSize: badgeSide, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, color]))
            NSImage(systemSymbolName: badgeSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(badgeConfig)?
                .draw(in: badgeRect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = accessibility
        return image
    }
}

/// Logo do cabeçalho do popover: o selo é o ponto de status de sempre, e vira
/// um "!" vermelho em erro.
struct AppLogoView: View {
    let indicator: AppIndicator
    let statusColor: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: AppIndicatorImage.logoSymbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundColor(.primary)
                .padding(.top, 4)
                .padding(.trailing, 4)
            if indicator == .error || indicator == .attention {
                Image(systemName: AppIndicatorImage.errorBadgeSymbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, indicator == .error ? Color.red : Color.orange)
                    .font(.system(size: 14, weight: .bold))
                    .accessibilityLabel("Erro")
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
        }
    }
}
