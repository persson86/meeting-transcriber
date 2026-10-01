import AppKit
import SwiftUI

/// O que o logo do app sinaliza, na barra de menu e no cabeçalho do popover.
/// Erro ganha um selo vermelho no próprio logo: o alerta precisa ser visto em
/// call e em compartilhamento de tela, quando a notificação costuma ficar
/// suprimida, e não pode ser confundido com o vermelho de "gravando".
enum AppIndicator: Equatable {
    case idle
    case recording
    case error

    static func make(status: RecordingStatus, micState: MicCaptureState) -> AppIndicator {
        switch status {
        case .error:
            return .error
        case .recording:
            return micState.needsAttention ? .error : .recording
        case .idle, .starting, .stopping, .importing:
            return .idle
        }
    }
}

enum AppIndicatorImage {
    static let logoSymbol = "mic.circle"
    static let errorBadgeSymbol = "exclamationmark.circle.fill"

    /// Logo do app com selo vermelho no canto superior direito. Não é template: o
    /// vermelho precisa sobreviver na barra de menu. O glifo usa `labelColor`,
    /// resolvido na hora do desenho, então acompanha o tema claro/escuro.
    static func logoWithErrorBadge(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let logoConfig = NSImage.SymbolConfiguration(pointSize: size * 0.78, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            if let logo = NSImage(systemSymbolName: logoSymbol, accessibilityDescription: nil)?
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
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
            NSImage(systemSymbolName: errorBadgeSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(badgeConfig)?
                .draw(in: badgeRect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Meeting Transcriber com erro"
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
            if indicator == .error {
                Image(systemName: AppIndicatorImage.errorBadgeSymbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
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
