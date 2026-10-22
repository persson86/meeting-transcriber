import AppKit
import SwiftUI

/// Pergunta pendente da assistência Teams, igual no menu e na janela de
/// revisão. Os botões são os únicos gestos que gravam ou encerram; Enter no
/// campo não inicia nada (nenhum botão é ação padrão).
struct AssistOfferCard: View {
    @EnvironmentObject var assistant: CallAssistant
    @EnvironmentObject var state: AppState
    var onDone: () -> Void = {}

    var body: some View {
        if let offer = assistant.offer {
            VStack(alignment: .leading, spacing: 8) {
                switch offer.kind {
                case .start: startContent(offer)
                case .end: endContent(offer)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.35)))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func startContent(_ offer: CallAssistant.Offer) -> some View {
        Label("Chamada do Teams detectada", systemImage: "phone.badge.waveform")
            .font(.callout.weight(.semibold))
        Text("Ainda não estamos gravando.")
            .font(.caption)
            .foregroundColor(.secondary)
        TextField("Título da transcrição (opcional)", text: $assistant.draftTitle)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Título da transcrição")
        Text(calendarHint)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Não gravar nesta chamada") {
                assistant.perform(.decline, offerID: offer.id)
                onDone()
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 8)
            Button {
                assistant.perform(.startNow, offerID: offer.id)
                onDone()
            } label: {
                Label("Gravar esta chamada", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.canStartCapture)
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private func endContent(_ offer: CallAssistant.Offer) -> some View {
        Label("A chamada parece ter terminado", systemImage: "phone.down")
            .font(.callout.weight(.semibold))
        Text("A gravação continua até você encerrar.")
            .font(.caption)
            .foregroundColor(.secondary)
        HStack {
            Button("Continuar gravando") {
                assistant.perform(.continueRecording, offerID: offer.id)
                onDone()
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 8)
            Button {
                assistant.perform(.stopAndTranscribe, offerID: offer.id)
                onDone()
            } label: {
                Label("Encerrar e transcrever", systemImage: "stop.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .controlSize(.large)
    }

    private var calendarHint: String {
        if assistant.isLookingUpCalendar { return "Consultando o Calendar… você já pode gravar." }
        if let meeting = assistant.suggestion,
           assistant.draftTitle == AppState.calendarTitle(for: meeting) {
            return "Sugerido pelo Calendar (“\(meeting.title)”) · editável. Sem título, usamos data e hora."
        }
        return "Sem título, usamos data e hora."
    }
}

/// Liga/desliga a assistência. Desligar nunca para uma gravação.
struct AssistanceToggleRow: View {
    @EnvironmentObject var assistant: CallAssistant

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { assistant.isEnabled }, set: { assistant.setEnabled($0) })) {
                Text("Perguntar ao entrar em chamada do Teams")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Observa só se o Teams está usando o microfone. Nunca grava nem encerra sem você confirmar.")
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detail: String? {
        switch assistant.availability {
        case .off: return nil
        case .observing:
            return assistant.assistedSessionID != nil
                ? "Perguntaremos quando a chamada parecer terminar."
                : nil
        case .unsupported: return "Requer macOS 14.2 ou posterior."
        case .unavailable: return "Não foi possível acompanhar o Teams agora. A gravação manual continua normal."
        }
    }
}

/// Janela aberta só por gesto explícito (clique no corpo da notificação):
/// a MenuBarExtra não tem API para abrir o popover por código.
@MainActor
final class AssistReviewWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let state: AppState
    private let assistant: CallAssistant

    init(state: AppState, assistant: CallAssistant) {
        self.state = state
        self.assistant = assistant
    }

    func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let root = AssistReviewView(onDone: { [weak self] in self?.close() })
            .environmentObject(state)
            .environmentObject(assistant)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Meeting Transcriber"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: root)
        panel.delegate = self
        return panel
    }
}

private struct AssistReviewView: View {
    @EnvironmentObject var assistant: CallAssistant
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if assistant.offer != nil {
                AssistOfferCard(onDone: onDone)
            } else {
                Text("Nenhuma pergunta pendente.")
                    .font(.callout.weight(.medium))
                Text("A oferta não está mais disponível; nada foi gravado ou encerrado por ela. Use o menu do Meeting Transcriber para gravar manualmente.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Fechar", action: onDone)
                }
            }
        }
        .padding(16)
        .frame(width: 420)
        // Esc fecha a janela sem decidir nada; o rascunho fica no CallAssistant.
        .background(EscapeCloses(onDone: onDone))
    }
}

private struct EscapeCloses: View {
    var onDone: () -> Void
    var body: some View {
        Button("", action: onDone)
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// Ícone da barra de menu: captura e pergunta pendente aparecem juntas.
struct MenuBarIcon: View {
    @ObservedObject var state: AppState
    @ObservedObject var assistant: CallAssistant

    var body: some View {
        let pending = assistant.offer != nil
        switch state.appIndicator {
        case .error:
            Image(nsImage: AppIndicatorImage.logoWithErrorBadge())
        case .attention:
            Image(nsImage: AppIndicatorImage.logoWithErrorBadge(color: .systemOrange))
        case .recording:
            if pending {
                Image(nsImage: AppIndicatorImage.recordingWithQuestionBadge())
            } else {
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
            }
        case .idle:
            if pending {
                Image(nsImage: AppIndicatorImage.logoWithErrorBadge(
                    color: .systemBlue,
                    badgeSymbol: AppIndicatorImage.questionBadgeSymbol,
                    accessibility: "Meeting Transcriber: chamada do Teams detectada, pergunta pendente"
                ))
            } else {
                Image(systemName: AppIndicatorImage.logoSymbol)
            }
        }
    }
}
