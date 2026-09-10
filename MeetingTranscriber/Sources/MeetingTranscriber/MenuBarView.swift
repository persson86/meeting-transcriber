import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum MenuLayout {
    static let popoverWidth: CGFloat = 400
    static let padding: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let controlSpacing: CGFloat = 8
    static let compactSpacing: CGFloat = 4
    static let statusDotSize: CGFloat = 10
    static let buttonLabelMinHeight: CGFloat = 24
    static let iconButtonSize: CGFloat = 28
    static let jobIconWidth: CGFloat = 20
}

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @State private var showDirPicker = false
    @State private var jobPendingCancellation: TranscriptionJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Status bar ───────────────────────────────────────────────
            HStack(spacing: MenuLayout.controlSpacing) {
                Circle()
                    .fill(statusColor)
                    .frame(
                        width: MenuLayout.statusDotSize,
                        height: MenuLayout.statusDotSize
                    )
                VStack(alignment: .leading, spacing: MenuLayout.compactSpacing) {
                    Text("Meeting Transcriber")
                        .font(.headline)
                    Text(state.statusLabel)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(MenuLayout.padding)

            Divider()

            // ── Warning banner (partial capture) ──────────────────────────
            if let warning = state.lastWarning {
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
                    .frame(
                        width: MenuLayout.iconButtonSize,
                        height: MenuLayout.iconButtonSize
                    )
                    .contentShape(Rectangle())
                    .foregroundColor(.secondary)
                    .help("Dispensar aviso")
                }
                .padding(MenuLayout.padding)

                Divider()
            }

            // ── Idle / active content ─────────────────────────────────────
            VStack(alignment: .leading, spacing: MenuLayout.sectionSpacing) {

                if case .idle = state.status {
                    VStack(alignment: .leading, spacing: MenuLayout.controlSpacing) {
                        Text("Título da reunião")
                            .font(.subheadline.weight(.medium))

                        TextField("Nome da reunião", text: $state.meetingTitle)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)

                        Button {
                            state.syncMeetingTitleFromCalendar()
                        } label: {
                            Label(
                                state.isCalendarSyncing
                                    ? "Sincronizando…"
                                    : "Usar próxima reunião do Calendar",
                                systemImage: "calendar"
                            )
                            .frame(
                                maxWidth: .infinity,
                                minHeight: MenuLayout.buttonLabelMinHeight
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(state.isCalendarSyncing)
                        .help("Preencher com a próxima reunião confirmada")
                    }

                    HStack {
                        Text("Idioma")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { state.language },
                            set: { state.setLanguage($0) }
                        )) {
                            Text("Português").tag("pt")
                            Text("Inglês").tag("en")
                            Text("Detectar automaticamente").tag("auto")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.large)
                    }

                } else if case .error(let msg) = state.status {
                    Text(msg)
                        .font(.body)
                        .foregroundColor(.orange)
                        .lineLimit(4)
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

                } else {
                    // Recording / stopping — show read-only info
                    HStack {
                        Text(state.meetingTitle)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(languageLabel(state.language))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    if state.status.isRecording {
                        Text("O indicador de compartilhamento do macOS é esperado durante a captura.")
                            .font(.callout)
                            .foregroundColor(.secondary)
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

                Button { handleAction() } label: {
                    Label(actionTitle, systemImage: actionIcon)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: MenuLayout.buttonLabelMinHeight
                        )
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(state.status.isRecording ? .red : .accentColor)
                    .disabled(
                        state.status.isStopping
                            || state.status.isStarting
                            || state.status.isImporting
                            || state.isCalendarSyncing
                            || !state.storageIsAvailable
                    )

                if case .idle = state.status {
                    Button {
                        chooseAudioFile()
                    } label: {
                        Label(
                            "Processar arquivo de áudio…",
                            systemImage: "waveform.badge.plus"
                        )
                        .frame(
                            maxWidth: .infinity,
                            minHeight: MenuLayout.buttonLabelMinHeight
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(state.isCalendarSyncing)
                    .help("Escolher um WAV de 16 kHz sem alterar o arquivo original")
                }

            }
            .padding(MenuLayout.padding)

            // ── Transcription queue ─────────────────────────────────────
            if !state.visibleTranscriptionJobs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: MenuLayout.controlSpacing) {
                    HStack {
                        Text("Transcrições")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(state.runningTranscriptionCount)/\(state.maxConcurrentTranscriptionCount)")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

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
                                    HStack(spacing: MenuLayout.compactSpacing) {
                                        Text(jobStatusLabel(job))
                                        Text("•")
                                        Text(timeLabel(job.createdAt))
                                    }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)

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
                                        .disabled(job.exportedToSecondBrain)
                                        .help(
                                            job.exportedToSecondBrain
                                                ? "Enviada ao second-brain"
                                                : "Enviar ao second-brain"
                                        )
                                    }
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
                .padding(MenuLayout.padding)
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

            // ── Last output ───────────────────────────────────────────────
            if let url = state.lastOutputURL {
                Divider()
                Button {
                    openTranscript(url)
                } label: {
                    Label(url.lastPathComponent, systemImage: "doc.text")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .padding(MenuLayout.padding)
            }

            // ── Footer ────────────────────────────────────────────────────
            Divider()

            HStack(spacing: MenuLayout.controlSpacing) {
                // Output folder
                Button {
                    NSWorkspace.shared.open(state.outputDirectory)
                } label: {
                    Label(
                        state.outputDirectory.lastPathComponent,
                        systemImage: "folder"
                    )
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Abrir no Finder")

                Button {
                    showDirPicker = true
                } label: {
                    Image(systemName: "pencil")
                        .frame(
                            width: MenuLayout.iconButtonSize,
                            height: MenuLayout.iconButtonSize
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.body)
                .help("Trocar pasta de saída")

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .frame(
                            width: MenuLayout.iconButtonSize,
                            height: MenuLayout.iconButtonSize
                        )
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.body)
                    .help("Encerrar")
            }
            .padding(MenuLayout.padding)
        }
        .frame(width: MenuLayout.popoverWidth)
        .fileImporter(isPresented: $showDirPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { state.setOutputDirectory(url) }
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
        case .recording: return "Parar e adicionar à fila"
        case .stopping:  return "Salvando áudio…"
        case .importing: return "Importando áudio…"
        case .error:     return "Tentar novamente"
        }
    }

    private var actionIcon: String {
        switch state.status {
        case .idle, .error: return "record.circle"
        case .starting: return "hourglass"
        case .recording: return "stop.circle"
        case .stopping: return "hourglass"
        case .importing: return "square.and.arrow.down"
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
        case .error:     return .orange
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
            return "Na fila"
        case .running:
            return "Em andamento"
        case .cancelling:
            return "Cancelando…"
        case .succeeded:
            return job.captureIntegrity.status == .degraded ? "Concluída com captura parcial" : "Concluída"
        case .failed(let message):
            return message
        }
    }

    private func jobIcon(_ job: TranscriptionJob) -> String {
        switch job.status {
        case .queued: return "clock"
        case .running: return "waveform"
        case .cancelling: return "stop.circle"
        case .succeeded:
            return job.captureIntegrity.status == .degraded ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func jobTint(_ job: TranscriptionJob) -> Color {
        switch job.status {
        case .queued: return .blue
        case .running: return .orange
        case .cancelling: return .orange
        case .succeeded: return job.captureIntegrity.status == .degraded ? .orange : .green
        case .failed: return .orange
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
