import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @State private var showDirPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Status bar ───────────────────────────────────────────────
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(state.statusLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // ── Idle / active content ─────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {

                if case .idle = state.status {
                    // Title field
                    TextField("Título da reunião", text: $state.meetingTitle)
                        .textFieldStyle(.roundedBorder)

                    // Language — menu dropdown evita overflow
                    HStack {
                        Text("Idioma")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { state.language },
                            set: { state.setLanguage($0) }
                        )) {
                            Text("🇧🇷 PT-BR").tag("pt")
                            Text("🇺🇸 English").tag("en")
                            Text("🌐 Auto-detect").tag("auto")
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }

                } else if case .error(let msg) = state.status {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Limpar erro") { state.resetError() }
                        .buttonStyle(.link)
                        .font(.caption)

                } else {
                    // Recording / stopping — show read-only info
                    HStack {
                        Text(state.meetingTitle)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(languageLabel(state.language))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if state.status.isRecording {
                        Text("O indicador \"Currently Sharing\" do macOS é esperado.")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    } else if state.status.isStopping {
                        Text("Finalizando arquivos de áudio antes de liberar a próxima gravação.")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }

                // Main action button
                Button(actionLabel) { handleAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(state.status.isRecording ? .red : .accentColor)
                    .disabled(state.status.isStopping)
                    .frame(maxWidth: .infinity)

            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // ── Transcription queue ─────────────────────────────────────
            if !state.visibleTranscriptionJobs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Fila de transcrições")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(state.runningTranscriptionCount)/\(state.maxConcurrentTranscriptionCount)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    ForEach(state.visibleTranscriptionJobs) { job in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: jobIcon(job.status))
                                .font(.caption)
                                .foregroundColor(jobTint(job.status))
                                .frame(width: 14)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(jobStatusLabel(job.status))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 4)

                            if case .succeeded(let url) = job.status {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "doc.text")
                                }
                                .buttonStyle(.plain)
                                .help("Abrir transcrição")
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }

            // ── Last output ───────────────────────────────────────────────
            if let url = state.lastOutputURL {
                Divider()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(url.lastPathComponent, systemImage: "doc.text")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            // ── Footer ────────────────────────────────────────────────────
            Divider()

            HStack(spacing: 0) {
                // Output folder
                Button {
                    showDirPicker = true
                } label: {
                    Label(
                        state.outputDirectory.lastPathComponent,
                        systemImage: "folder"
                    )
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Sair") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
                    .foregroundColor(.secondary)
                    .font(.caption2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 260)
        .fileImporter(isPresented: $showDirPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { state.setOutputDirectory(url) }
        }
    }

    // MARK: - Helpers

    private var actionLabel: String {
        switch state.status {
        case .idle:      return "⏺  Iniciar gravação"
        case .recording: return "⏹  Parar e enfileirar"
        case .stopping:  return "Salvando áudio..."
        case .error:     return "⏺  Tentar novamente"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .idle:
            if state.runningTranscriptionCount > 0 { return .orange }
            if state.queuedTranscriptionCount > 0 { return .blue }
            return .green.opacity(0.7)
        case .recording: return .red
        case .stopping:  return .orange
        case .error:     return .orange
        }
    }

    private func languageLabel(_ lang: String) -> String {
        switch lang {
        case "pt":  return "🇧🇷 PT-BR"
        case "en":  return "🇺🇸 EN"
        default:    return "🌐 Auto"
        }
    }

    private func handleAction() {
        switch state.status {
        case .idle, .error:
            state.resetError()
            state.startRecording()
        case .recording:
            state.stopRecording()
        case .stopping:
            break
        }
    }

    private func jobStatusLabel(_ status: TranscriptionJobStatus) -> String {
        switch status {
        case .queued:
            return "Aguardando"
        case .running:
            return "Processando"
        case .succeeded:
            return "Concluída"
        case .failed(let message):
            return message
        }
    }

    private func jobIcon(_ status: TranscriptionJobStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "waveform"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func jobTint(_ status: TranscriptionJobStatus) -> Color {
        switch status {
        case .queued: return .blue
        case .running: return .orange
        case .succeeded: return .green
        case .failed: return .orange
        }
    }
}
