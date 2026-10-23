import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MenuLayout {
    static let popoverWidth: CGFloat = 400
    static let padding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let controlSpacing: CGFloat = 8
    static let compactSpacing: CGFloat = 4
    static let buttonLabelMinHeight: CGFloat = 24
    static let iconButtonSize: CGFloat = 28
    static let jobIconWidth: CGFloat = 20
    static let boxPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 10
}

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var assistant: CallAssistant
    @State private var showDirPicker = false
    /// Edição do título durante a gravação (2.0): Enter aplica, Esc cancela.
    @State private var editingTitle: String?
    @FocusState private var titleFieldFocused: Bool
    @State private var jobPendingCancellation: TranscriptionJob?
    @State private var showingSettings: Bool

    init(showingSettings: Bool = false) {
        _showingSettings = State(initialValue: showingSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `onAppear` do MenuBarExtra pode disparar só na 1ª abertura; a janela
            // virar key a cada abertura é o sinal confiável de que a lista foi vista.
            Color.clear.frame(height: 0)
                .onAppear { state.acknowledgeJobProblems() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    state.acknowledgeJobProblems()
                }

            header
            Divider()

            if let warning = state.lastWarning {
                warningBanner(warning)
                Divider()
            }

            if showingSettings {
                settings
                    .padding(MenuLayout.padding)
            } else {
                VStack(alignment: .leading, spacing: MenuLayout.sectionSpacing) {
                    if showsCapture {
                        captureContent
                    } else {
                        idleContent
                    }
                }
                .padding(MenuLayout.padding)

                Divider()
                AssistanceRow()
                    .padding(.horizontal, MenuLayout.padding)
                    .padding(.vertical, MenuLayout.controlSpacing + 2)

                Divider()
                jobsSection
                    .padding(MenuLayout.padding)
            }

            Divider()
            footer
                .padding(.horizontal, MenuLayout.padding)
                .padding(.vertical, MenuLayout.controlSpacing + 2)
        }
        .frame(width: MenuLayout.popoverWidth)
        .fileImporter(isPresented: $showDirPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { state.setOutputDirectory(url) }
        }
    }

    // MARK: - Regiões

    private var header: some View {
        HStack(spacing: MenuLayout.controlSpacing + 2) {
            AppLogoView(indicator: state.appIndicator, statusColor: statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Transcriber")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(headerDotColor).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(headerStatus)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, MenuLayout.padding)
        .padding(.vertical, MenuLayout.padding - 4)
        .accessibilityElement(children: .combine)
    }

    private func warningBanner(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: MenuLayout.controlSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundColor(.orange)
            Text(warning)
                .font(.callout)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: MenuLayout.compactSpacing)
            Button {
                state.clearWarning()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .frame(width: MenuLayout.iconButtonSize, height: MenuLayout.iconButtonSize)
            .contentShape(Rectangle())
            .foregroundColor(.secondary)
            .help("Dispensar aviso")
        }
        .padding(MenuLayout.padding)
    }

    /// Sem gravação: pergunta de início (se houver) ou o formulário manual.
    @ViewBuilder private var idleContent: some View {
        if case .error(let msg) = state.status {
            errorBlock(msg)
        }
        if let offer = assistant.offer, offer.kind == .start, case .idle = state.status {
            StartOfferForm(offer: offer)
        } else {
            TitleFieldBlock(
                text: $state.meetingTitle,
                hint: state.isCalendarSyncing ? "Consultando o Calendar…" : "O título não é obrigatório para gravar.",
                hintIcon: "text.cursor"
            )
            Button {
                state.syncMeetingTitleFromCalendar()
            } label: {
                Label(
                    state.isCalendarSyncing ? "Sincronizando…" : "Usar reunião atual ou próxima do Calendar",
                    systemImage: "calendar"
                )
                .font(.callout)
            }
            .buttonStyle(.link)
            .disabled(state.isCalendarSyncing)
            .help("Preencher com a reunião confirmada em andamento ou a próxima; se você editar o título, o evento deixa de ser associado")

            LanguageRow()

            Button { handleAction() } label: {
                Label(actionTitle, systemImage: actionIcon)
                    .frame(maxWidth: .infinity, minHeight: MenuLayout.buttonLabelMinHeight)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state.isCalendarSyncing || !state.storageIsAvailable)

            if case .idle = state.status {
                Button {
                    chooseAudioFile()
                } label: {
                    Label("Processar arquivo de áudio…", systemImage: "waveform.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.link)
                .disabled(state.isCalendarSyncing)
                .help("Escolher um WAV de 16 kHz sem alterar o arquivo original")
            }
        }
    }

    private func errorBlock(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: MenuLayout.controlSpacing) {
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundColor(.orange)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: MenuLayout.sectionSpacing) {
                Button {
                    state.resetError()
                } label: {
                    Label("Limpar", systemImage: "xmark.circle")
                }
                .buttonStyle(.link)
                .font(.callout)

                if msg.contains("ermissão") || msg.contains("ermission") {
                    Button {
                        let pane = (msg.contains("icrofone") || msg.contains("icrophone"))
                            ? "Privacy_Microphone"
                            : "Privacy_ScreenCapture"
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    } label: {
                        Label("Abrir Configurações", systemImage: "gear")
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
        }
    }

    /// Gravando: pergunta de fim, título, origem, tempo e saúde das trilhas.
    @ViewBuilder private var captureContent: some View {
        if case .error(let msg) = state.status {
            errorBlock(msg)
        }
        if let offer = assistant.offer, offer.kind == .end {
            EndOfferBox(offer: offer)
        }

        if let draft = editingTitle, state.status.isRecording {
            VStack(alignment: .leading, spacing: MenuLayout.controlSpacing) {
                TitleFieldBlock(
                    text: Binding(get: { draft }, set: { editingTitle = $0 }),
                    hint: "Enter aplica; Esc cancela. A gravação não é afetada.",
                    hintIcon: "keyboard",
                    focus: $titleFieldFocused,
                    onSubmit: applyTitleEdit,
                    onCancel: { editingTitle = nil }
                )
                DecisionButtons(
                    secondary: "Cancelar",
                    primary: "Concluir edição",
                    onSecondary: { editingTitle = nil },
                    onPrimary: applyTitleEdit
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.meetingTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(state.meetingTitle)
                    Spacer(minLength: MenuLayout.controlSpacing)
                    if state.status.isRecording {
                        Button("Editar título") {
                            editingTitle = state.meetingTitle
                            titleFieldFocused = true
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }
                if let origin = state.currentOrigin {
                    Text("\(originLabel(origin)) · \(languageLabel(state.language))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }

        if let proof = state.captureProof {
            DurationRow(proof: proof, status: state.status)
            CaptureProofView(proof: proof)
        } else if !state.status.isRecording {
            Text(state.status.label)
                .font(.callout)
                .foregroundColor(.secondary)
        }

        if state.status.isRecording, let alert = state.captureAlert {
            VStack(alignment: .leading, spacing: MenuLayout.controlSpacing) {
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    state.restartMicrophone()
                } label: {
                    Label("Reiniciar microfone", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: MenuLayout.buttonLabelMinHeight)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
                .disabled(!state.canRestartMicrophone)
                .help("Rearma a captura do microfone sem parar a gravação; o intervalo sem áudio fica registrado")
            }
        } else if state.status.isRecording, state.micCaptureState == .waitingForAudio {
            Label("Confirmando o áudio do microfone…", systemImage: "waveform")
                .font(.callout)
                .foregroundColor(.secondary)
        }

        captureAction

        if state.status.isRecording {
            Text("O indicador de compartilhamento do macOS é esperado durante a captura.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if state.status.isStopping {
            Text("Salvando o áudio antes de liberar a próxima gravação.")
                .font(.callout)
                .foregroundColor(.secondary)
        } else if state.status.isImporting {
            Text("Copiando o áudio selecionado para a fila de transcrição.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private var captureAction: some View {
        Button { handleAction() } label: {
            Label(actionTitle, systemImage: actionIcon)
                .frame(maxWidth: .infinity, minHeight: MenuLayout.buttonLabelMinHeight)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(.red)
        .disabled(state.status.isStopping || state.status.isStarting || state.status.isImporting)
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: MenuLayout.controlSpacing) {
            HStack {
                Text("Transcrições recentes")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if state.runningTranscriptionCount + state.queuedTranscriptionCount > 0 {
                    Text("\(state.runningTranscriptionCount)/\(state.maxConcurrentTranscriptionCount)")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .help("Transcrições rodando / limite simultâneo")
                }
            }

            if let reason = state.transcriptionPauseReason, reason.canOverride,
               state.runningTranscriptionCount + state.queuedTranscriptionCount > 0 {
                // Adiamento (bateria/chamada): a pessoa pode furar.
                HStack(spacing: MenuLayout.controlSpacing) {
                    Label(
                        reason == .call ? "Em pausa enquanto a chamada dura" : "Em pausa até ligar na tomada",
                        systemImage: reason == .call ? "phone" : "battery.50"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    Spacer()
                    Button("Retomar agora") { state.resumeTranscriptionsNow() }
                        .controlSize(.small)
                }
            }

            if state.visibleTranscriptionJobs.isEmpty {
                Text(showsCapture ? "O processamento começa quando a gravação terminar." : "Suas transcrições aparecerão aqui.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: MenuLayout.controlSpacing) {
                    ForEach(state.visibleTranscriptionJobs) { job in
                        HStack(alignment: .top, spacing: MenuLayout.controlSpacing) {
                            Image(systemName: jobIcon(job))
                                .font(.body)
                                .foregroundColor(jobTint(job))
                                .frame(width: MenuLayout.jobIconWidth)

                            VStack(alignment: .leading, spacing: MenuLayout.compactSpacing) {
                                Text(job.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                HStack(alignment: .top, spacing: MenuLayout.compactSpacing) {
                                    Text(jobStatusLabel(job))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .help(jobStatusLabel(job))
                                    Text("•")
                                    Text(timeLabel(job.createdAt))
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(job.status.isFinished ? 4 : 1)

                                if let sideError = job.sideError {
                                    Text(sideError)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .lineLimit(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .help(sideError)
                                }

                                if job.status.isRunning {
                                    HStack(spacing: MenuLayout.controlSpacing) {
                                        ProgressView(value: Double(job.progress), total: 100)
                                            .progressViewStyle(.linear)
                                        Text("\(job.progress)%")
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }

                            Spacer(minLength: MenuLayout.compactSpacing)

                            if case .succeeded(let url) = job.status {
                                Button {
                                    openTranscript(url)
                                } label: {
                                    Image(systemName: "doc.text")
                                        .frame(
                                            width: MenuLayout.iconButtonSize,
                                            height: MenuLayout.iconButtonSize
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Abrir transcrição")

                                if AppConfig.secondBrainPath != nil {
                                    Button {
                                        state.sendToSecondBrain(job)
                                    } label: {
                                        Image(systemName: job.exportedToSecondBrain ? "checkmark.circle" : "brain")
                                            .frame(
                                                width: MenuLayout.iconButtonSize,
                                                height: MenuLayout.iconButtonSize
                                            )
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(job.exportedToSecondBrain || state.status.isCapturing)
                                    .help(
                                        job.exportedToSecondBrain
                                            ? "Enviada ao second-brain"
                                            : state.status.isCapturing
                                                ? "Disponível após a gravação"
                                                : (job.sideError ?? "Enviar ao second-brain")
                                    )
                                }
                            }

                            if case .failed = job.status, let logURL = state.pipelineLogURL(for: job.id) {
                                Button {
                                    NSWorkspace.shared.open(logURL)
                                } label: {
                                    Image(systemName: "doc.plaintext")
                                        .frame(
                                            width: MenuLayout.iconButtonSize,
                                            height: MenuLayout.iconButtonSize
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Abrir o log do pipeline")
                            }

                            if case .failed = job.status,
                               job.micURL != nil || job.systemURL != nil {
                                Button {
                                    state.retryJob(job.id)
                                } label: {
                                    Image(systemName: "arrow.clockwise.circle")
                                        .frame(
                                            width: MenuLayout.iconButtonSize,
                                            height: MenuLayout.iconButtonSize
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Tentar novamente com o áudio preservado")
                            }

                            Button {
                                if job.status.isFinished {
                                    state.dismissJob(job.id)
                                } else {
                                    jobPendingCancellation = job
                                }
                            } label: {
                                Image(systemName: dismissIcon(job.status))
                                    .foregroundColor(dismissTint(job.status))
                                    .frame(
                                        width: MenuLayout.iconButtonSize,
                                        height: MenuLayout.iconButtonSize
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(job.status.isFinished ? "Remover da lista" : "Cancelar processamento")
                        }
                        .padding(.vertical, MenuLayout.compactSpacing)
                    }
                }
            }
        }
        .confirmationDialog(
                    "Cancelar esta transcrição?",
                    isPresented: Binding(
                        get: { jobPendingCancellation != nil },
                        set: { if !$0 { jobPendingCancellation = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: jobPendingCancellation
                ) { job in
                    Button("Cancelar processamento") {
                        state.cancelJob(job.id)
                        jobPendingCancellation = nil
                    }
                    Button("Manter na fila", role: .cancel) {
                        jobPendingCancellation = nil
                    }
                } message: { job in
                    Text("“\(job.title)” será interrompida. O áudio ficará preservado para tentar novamente.")
                }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: MenuLayout.sectionSpacing) {
            Text("Configurações")
                .font(.headline)

            settingToggle(
                "Assistência Teams",
                detail: "Oferece gravar quando o Teams usa o microfone e encerrar quando a chamada parece terminar. Nunca grava nem encerra sem você confirmar; desligar não para a gravação.",
                isOn: Binding(get: { assistant.isEnabled }, set: { assistant.setEnabled($0) })
            )
            .disabled(!CallAssistant.platformSupported)

            settingToggle(
                "Transcrever só na tomada e fora de chamadas",
                detail: "Na bateria ou em chamada do Teams a transcrição pausa e continua de onde parou.",
                isOn: Binding(get: { state.deferTranscriptionWhenBusy }, set: { state.setDeferTranscriptionWhenBusy($0) })
            )

            VStack(alignment: .leading, spacing: MenuLayout.compactSpacing) {
                Text("Pasta das transcrições")
                    .font(.callout.weight(.semibold))
                HStack {
                    Text(state.outputDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(state.outputDirectory.path)
                    Spacer()
                    Button("Trocar…") { showDirPicker = true }
                        .controlSize(.small)
                }
            }

            Button {
                showingSettings = false
            } label: {
                Text("Voltar aos controles")
                    .frame(maxWidth: .infinity, minHeight: MenuLayout.buttonLabelMinHeight)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func settingToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer(minLength: MenuLayout.controlSpacing)
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: MenuLayout.controlSpacing) {
            Button {
                NSWorkspace.shared.open(state.outputDirectory)
            } label: {
                Label(state.outputDirectory.lastPathComponent, systemImage: "folder")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Abrir a pasta das transcrições no Finder")

            if let url = state.lastOutputURL {
                Button {
                    openTranscript(url)
                } label: {
                    Image(systemName: "doc.text")
                        .frame(width: MenuLayout.iconButtonSize, height: MenuLayout.iconButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Abrir a última transcrição: \(url.lastPathComponent)")
            }

            Spacer()

            Text(AppVersion.label)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .help("Versão do app e do pipeline de transcrição")

            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "gearshape.fill" : "gearshape")
                    .frame(width: MenuLayout.iconButtonSize, height: MenuLayout.iconButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Configurações")
            .accessibilityLabel("Configurações")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: MenuLayout.iconButtonSize, height: MenuLayout.iconButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Encerrar o app")
            .accessibilityLabel("Encerrar o app")
        }
    }

    /// Captura ativa, ou erro com recorder ainda aberto: o controle é Encerrar.
    private var showsCapture: Bool {
        state.status.isCapturing || state.status.isImporting || (state.status.isError && state.hasActiveRecorder)
    }

    private var headerStatus: String {
        switch state.status {
        case .recording: return "Gravando"
        case .starting, .stopping, .importing: return state.status.label
        case .error: return state.hasActiveRecorder ? "Gravando · precisa de atenção" : "Precisa de atenção"
        case .idle:
            var parts = ["Não está gravando"]
            if assistant.offer?.kind == .start {
                parts.append("decisão pendente")
            } else if state.runningTranscriptionCount > 0 {
                parts.append(state.transcriptionsPaused ? "transcrição em pausa" : "transcrevendo")
            } else if state.queuedTranscriptionCount > 0 {
                parts.append("\(state.queuedTranscriptionCount) na fila")
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Helpers

    /// Abre uma transcrição concluída. Prefere o Sublime Text; se não estiver
    /// instalado, deixa o usuário escolher o programa em vez de cair num app
    /// qualquer que o macOS tenha associado à extensão.
    private func openTranscript(_ url: URL) {
        if let sublimeURL = Self.sublimeTextURL() {
            NSWorkspace.shared.open([url], withApplicationAt: sublimeURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            promptForApplication(toOpen: url)
        }
    }

    private static func sublimeTextURL() -> URL? {
        ["com.sublimetext.4", "com.sublimetext.3", "com.sublimetext.2"]
            .lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    private func promptForApplication(toOpen url: URL) {
        let panel = NSOpenPanel()
        panel.title = "Abrir com…"
        panel.message = "Sublime Text não foi encontrado. Escolha outro programa para abrir \"\(url.lastPathComponent)\"."
        panel.prompt = "Abrir"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Processar arquivo de áudio"
        panel.message = "Escolha um WAV de 16 kHz para adicionar à fila de transcrição."
        panel.prompt = "Processar"
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first

        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.importAudioFile(url)
    }

    private var actionTitle: String {
        switch state.status {
        case .idle:      return "Iniciar gravação"
        case .starting:  return "Iniciando gravação…"
        case .recording: return "Encerrar gravação"
        case .stopping:  return "Salvando áudio…"
        case .importing: return "Importando áudio…"
        case .error:     return state.hasActiveRecorder ? "Encerrar gravação" : "Iniciar nova gravação"
        }
    }

    private var actionIcon: String {
        switch state.status {
        case .idle: return "record.circle"
        case .error: return state.hasActiveRecorder ? "stop.fill" : "record.circle"
        case .starting: return "hourglass"
        case .recording: return "stop.fill"
        case .stopping: return "hourglass"
        case .importing: return "square.and.arrow.down"
        }
    }

    /// Ponto do cabeçalho: só gravação e problema ganham cor; o resto é neutro.
    private var headerDotColor: Color {
        switch state.status {
        case .recording: return .red
        case .starting, .stopping: return .orange
        case .error: return .orange
        case .idle, .importing: return Color.secondary.opacity(0.6)
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .idle:
            if state.runningTranscriptionCount > 0 { return .orange }
            if state.queuedTranscriptionCount > 0 { return .blue }
            return .green.opacity(0.7)
        case .starting:  return .orange
        case .recording: return .red
        case .stopping:  return .orange
        case .importing: return .blue
        case .error:     return .red
        }
    }

    private func applyTitleEdit() {
        if let draft = editingTitle { state.renameActiveRecording(draft) }
        editingTitle = nil
    }

    private func originLabel(_ origin: RecordingOrigin) -> String {
        switch origin {
        case .manual:
            return "Iniciada manualmente · encerramento manual"
        case .assisted:
            return "Iniciada após sua confirmação"
        }
    }

    private func languageLabel(_ lang: String) -> String {
        switch lang {
        case "pt":  return "PT"
        case "en":  return "EN"
        default:    return "Automático"
        }
    }

    private func handleAction() {
        switch state.status {
        case .error where state.hasActiveRecorder:
            state.stopRecording()
        case .idle, .error:
            state.resetError()
            state.startRecording()
        case .starting:
            break
        case .recording:
            state.stopRecording()
        case .stopping:
            break
        case .importing:
            break
        }
    }

    private func jobStatusLabel(_ job: TranscriptionJob) -> String {
        switch job.status {
        case .queued:
            return state.transcriptionPauseReason?.queuedLabel ?? "Na fila"
        case .running:
            return state.transcriptionPauseReason?.runningLabel ?? "Em andamento"
        case .cancelling:
            return "Cancelando…"
        case .succeeded, .failed:
            return JobPresentation.result(for: job).listText
        }
    }

    private func jobIcon(_ job: TranscriptionJob) -> String {
        switch job.status {
        case .queued: return "clock"
        case .running: return "waveform"
        case .cancelling: return "stop.circle"
        case .succeeded, .failed: return JobPresentation.result(for: job).symbol
        }
    }

    private func jobTint(_ job: TranscriptionJob) -> Color {
        switch job.status {
        case .queued: return .blue
        case .running: return .orange
        case .cancelling: return .orange
        case .succeeded, .failed:
            switch JobPresentation.result(for: job).level {
            case .complete: return .green
            case .minorLoss: return .yellow
            case .partial: return .orange
            case .failed: return .red
            }
        }
    }

    /// Concluída: some da lista, sem excluir o áudio. Ativa: interrompe somente o
    /// processamento; o áudio fica disponível para uma nova tentativa.
    private func dismissIcon(_ status: TranscriptionJobStatus) -> String {
        status.isFinished ? "xmark.circle" : "stop.circle"
    }

    private func dismissTint(_ status: TranscriptionJobStatus) -> Color {
        status.isFinished ? .secondary : .red
    }

    /// Reaproveitado entre linhas e re-renders: `transcriptionJobs` republica a cada
    /// tick de progresso, e alocar um DateFormatter por linha custa caro à toa.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private func timeLabel(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}


/// F5: por trilha, tempo gravado, idade do último sinal e dispositivo efetivo.
/// Cronômetro grande da gravação; "Iniciando…" enquanto as trilhas abrem.
private struct DurationRow: View {
    let proof: CaptureProof
    let status: RecordingStatus

    var body: some View {
        HStack(alignment: .center) {
            Text(CaptureProof.clock(proof.elapsed))
                .font(.system(size: 28, weight: .regular, design: .monospaced))
                .monospacedDigit()
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(proof.isOpening ? Color.orange : Color.red)
                    .frame(width: 6, height: 6)
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        if status.isStopping { return "Salvando o áudio" }
        return proof.isOpening ? "Iniciando a captura" : "Gravação em andamento"
    }
}

/// Saúde das trilhas: uma linha por fonte, nível como barras coloridas.
private struct CaptureProofView: View {
    let proof: CaptureProof

    var body: some View {
        VStack(alignment: .leading, spacing: MenuLayout.controlSpacing + 1) {
            row(proof.mic, icon: "mic")
            row(proof.system, icon: "speaker.wave.2")
        }
        .padding(MenuLayout.boxPadding - 1)
        .overlay(
            RoundedRectangle(cornerRadius: MenuLayout.cornerRadius - 2)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private func row(_ track: TrackProof, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                Text(track.title)
                    .font(.callout)
                Spacer(minLength: MenuLayout.compactSpacing)
                Text(track.device)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                LevelBars(color: color(track.level), active: track.level == .green)
            }
            if track.level != .green {
                Text(track.detail)
                    .font(.caption)
                    .foregroundColor(color(track.level))
                    .padding(.leading, 23)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("\(track.title): \(CaptureProof.clock(track.secondsWritten)) gravados · \(track.detail)")
        .accessibilityElement(children: .combine)
    }

    private func color(_ level: ProofLevel) -> Color {
        switch level {
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        }
    }
}

/// Medidor estático: cor diz o estado; não é VU real, é prova de sinal.
private struct LevelBars: View {
    let color: Color
    let active: Bool
    private let heights: [CGFloat] = [6, 11, 8, 12, 5]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(heights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(active ? 1 : 0.6))
                    .frame(width: 3, height: active ? heights[index] : 3)
            }
        }
        .frame(width: 26, height: 13, alignment: .trailing)
        .accessibilityHidden(true)
    }
}
