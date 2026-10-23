import AppKit
import SwiftUI

/// Caixa de decisão (início/fim/ativação): pergunta, contexto e os botões.
struct QuestionBox<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: MenuLayout.controlSpacing) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(MenuLayout.boxPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MenuLayout.cornerRadius).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: MenuLayout.cornerRadius).stroke(Color.accentColor.opacity(0.28)))
        .accessibilityElement(children: .contain)
    }
}

/// Dois botões lado a lado que quebram linha em vez de truncar.
struct DecisionButtons: View {
    let secondary: String
    let primary: String
    var primaryIcon: String? = nil
    var primaryTint: Color? = nil
    var primaryDisabled = false
    let onSecondary: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        HStack(spacing: MenuLayout.controlSpacing) {
            Button(action: onSecondary) {
                Text(secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: MenuLayout.buttonLabelMinHeight)
            }
            .buttonStyle(.bordered)
            Button(action: onPrimary) {
                Group {
                    if let primaryIcon {
                        Label(primary, systemImage: primaryIcon)
                    } else {
                        Text(primary)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: MenuLayout.buttonLabelMinHeight)
            }
            .buttonStyle(.borderedProminent)
            .tint(primaryTint)
            .disabled(primaryDisabled)
        }
        .controlSize(.large)
    }
}

/// Campo de título com rótulo, "(opcional)" e uma dica com ícone.
struct TitleFieldBlock: View {
    @Binding var text: String
    let hint: String
    var hintIcon = "calendar"
    var focus: FocusState<Bool>.Binding? = nil
    var onSubmit: () -> Void = {}
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MenuLayout.compactSpacing + 2) {
            (Text("Título da transcrição ").font(.subheadline.weight(.semibold))
                + Text("(opcional)").font(.subheadline).foregroundColor(.secondary))
            field
            Label(hint, systemImage: hintIcon)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var field: some View {
        let base = TextField("Sem título, usaremos data e hora", text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .accessibilityLabel("Título da transcrição")
            .onSubmit(onSubmit)
            .onExitCommand { onCancel?() }
        if let focus { base.focused(focus) } else { base }
    }
}

struct LanguageRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            Text("Idioma")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Picker("Idioma da transcrição", selection: Binding(
                get: { state.language },
                set: { state.setLanguage($0) }
            )) {
                Text("Português").tag("pt")
                Text("Inglês").tag("en")
                Text("Detectar automaticamente").tag("auto")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Oferta de início: o formulário do menu vira a revisão da chamada. Um só
/// título, um só botão de início; Enter no campo não grava.
struct StartOfferForm: View {
    @EnvironmentObject var assistant: CallAssistant
    @EnvironmentObject var state: AppState
    let offer: CallAssistant.Offer
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: MenuLayout.sectionSpacing) {
            QuestionBox(
                title: "Deseja gravar esta chamada?",
                message: "Ainda não estamos gravando. O Teams está usando áudio, o que não prova que é uma reunião."
            ) { EmptyView() }
            TitleFieldBlock(text: $assistant.draftTitle, hint: calendarHint)
            LanguageRow()
            Text("Perguntaremos quando a chamada parecer terminar.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DecisionButtons(
                secondary: "Não gravar nesta chamada",
                primary: "Iniciar gravação",
                primaryIcon: "record.circle",
                primaryDisabled: !state.canStartCapture,
                onSecondary: {
                    assistant.perform(.decline, offerID: offer.id)
                    onDone()
                },
                onPrimary: {
                    assistant.perform(.startNow, offerID: offer.id)
                    onDone()
                }
            )
        }
    }

    private var calendarHint: String {
        if assistant.isLookingUpCalendar { return "Consultando o Calendar… Você já pode gravar." }
        if let meeting = assistant.suggestion,
           assistant.draftTitle == AppState.calendarTitle(for: meeting) {
            return "Sugerido pelo Calendar · editável"
        }
        return "O título não é obrigatório para gravar."
    }
}

/// Pergunta de fim, acima da gravação em curso.
struct EndOfferBox: View {
    @EnvironmentObject var assistant: CallAssistant
    let offer: CallAssistant.Offer
    var onDone: () -> Void = {}

    var body: some View {
        QuestionBox(
            title: "Deseja encerrar a gravação?",
            message: "A atividade do Teams mudou. Sem resposta, a gravação continua."
        ) {
            DecisionButtons(
                secondary: "Continuar gravando",
                primary: "Encerrar e transcrever",
                onSecondary: {
                    assistant.perform(.continueRecording, offerID: offer.id)
                    onDone()
                },
                onPrimary: {
                    assistant.perform(.stopAndTranscribe, offerID: offer.id)
                    onDone()
                }
            )
        }
    }
}

/// Linha da assistência: estado em uma frase e um controle (Ativar…, Pausar,
/// Retomar). Desligar fica nas configurações. Nada aqui grava ou encerra.
struct AssistanceRow: View {
    @EnvironmentObject var assistant: CallAssistant
    @EnvironmentObject var state: AppState
    @State private var preparing: Bool

    init(preparing: Bool = false) {
        _preparing = State(initialValue: preparing)
    }

    var body: some View {
        if preparing, !assistant.isEnabled {
            QuestionBox(
                title: "Ativar assistência Teams?",
                message: "Receba ofertas de início e fim. Só sua confirmação grava. A captura usa microfone e áudio do sistema."
            ) {
                DecisionButtons(
                    secondary: "Agora não",
                    primary: "Ativar assistência",
                    onSecondary: { preparing = false },
                    onPrimary: {
                        assistant.setEnabled(true)
                        preparing = false
                    }
                )
            }
        } else {
            HStack(spacing: MenuLayout.controlSpacing + 2) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Assistência Teams")
                        .font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: MenuLayout.controlSpacing)
                if let control {
                    Button(control.title, action: control.action)
                        .controlSize(.small)
                        .help(control.help)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var detail: String {
        if !assistant.isEnabled { return "Desligada. Inicie e encerre pelo botão." }
        if assistant.isPaused { return "Pausada até você retomar" }
        switch assistant.availability {
        case .unsupported: return "Requer macOS 14.2 ou posterior."
        case .unavailable: return "Indisponível agora. Use os controles manuais."
        case .off, .observing: break
        }
        if state.status.isCapturing {
            return assistant.assistedSessionID != nil
                ? "Perguntaremos quando a chamada parecer terminar"
                : "Sem pergunta de fim nesta gravação"
        }
        return "Observando atividade do Teams"
    }

    private var control: (title: String, help: String, action: () -> Void)? {
        if !assistant.isEnabled {
            guard CallAssistant.platformSupported else { return nil }
            return ("Ativar…", "Oferecer gravar ao entrar numa chamada do Teams", { preparing = true })
        }
        if assistant.isPaused {
            return ("Retomar", "Voltar a observar o Teams; a gravação atual não ganha pergunta de fim", { assistant.setPaused(false) })
        }
        return ("Pausar", "Parar de observar o Teams sem mexer na gravação", { assistant.setPaused(true) })
    }
}

/// Conteúdo da janela de revisão (clique no corpo da notificação).
struct AssistOfferCard: View {
    @EnvironmentObject var assistant: CallAssistant
    var onDone: () -> Void = {}

    var body: some View {
        if let offer = assistant.offer {
            switch offer.kind {
            case .start: StartOfferForm(offer: offer, onDone: onDone)
            case .end: EndOfferBox(offer: offer, onDone: onDone)
            }
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
        if let size = panel.contentView?.fittingSize, size.height > 0 { panel.setContentSize(size) }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let root = AssistReviewView(onDone: { [weak self] in self?.close() })
            .environmentObject(state)
            .environmentObject(assistant)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
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
