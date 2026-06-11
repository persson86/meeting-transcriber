import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @State private var showDirPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Status bar ───────────────────────────────────────────────
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Meeting Transcriber")
                        .font(.caption.weight(.semibold))
                    Text(state.statusLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            // ── Idle / active content ─────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {

                if case .idle = state.status {
                    TextField("Meeting title", text: $state.meetingTitle)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("Language")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { state.language },
                            set: { state.setLanguage($0) }
                        )) {
                            Text("Portuguese").tag("pt")
                            Text("English").tag("en")
                            Text("Auto-detect").tag("auto")
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }

                } else if case .error(let msg) = state.status {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button {
                            state.resetError()
                        } label: {
                            Label("Limpar", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.link)
                        .font(.caption)

                        if msg.contains("ermissão") || msg.contains("ermission") {
                            Button {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            } label: {
                                Label("Abrir Configurações", systemImage: "gear")
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }

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
                        Text("The macOS sharing indicator is expected while capture is active.")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    } else if state.status.isStopping {
                        Text("Saving audio before the next recording can start.")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }

                Button { handleAction() } label: {
                    Label(actionTitle, systemImage: actionIcon)
                        .frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(state.status.isRecording ? .red : .accentColor)
                    .disabled(state.status.isStopping)

            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // ── Transcription queue ─────────────────────────────────────
            if !state.visibleTranscriptionJobs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Queue")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(state.runningTranscriptionCount)/\(state.maxConcurrentTranscriptionCount)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
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
                                HStack(spacing: 4) {
                                    Text(jobStatusLabel(job.status))
                                    Text("•")
                                    Text(timeLabel(job.createdAt))
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            if case .succeeded(let url) = job.status {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "doc.text")
                                }
                                .buttonStyle(.plain)
                                .help("Open transcript")
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

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                    .buttonStyle(.link)
                    .foregroundColor(.secondary)
                    .font(.caption2)
                    .help("Quit")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
        .fileImporter(isPresented: $showDirPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { state.setOutputDirectory(url) }
        }
    }

    // MARK: - Helpers

    private var actionTitle: String {
        switch state.status {
        case .idle:      return "Start recording"
        case .recording: return "Stop and queue"
        case .stopping:  return "Saving audio..."
        case .error:     return "Try again"
        }
    }

    private var actionIcon: String {
        switch state.status {
        case .idle, .error: return "record.circle"
        case .recording: return "stop.circle"
        case .stopping: return "hourglass"
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
        case "pt":  return "PT"
        case "en":  return "EN"
        default:    return "Auto"
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
            return "Queued"
        case .running:
            return "Running"
        case .succeeded:
            return "Done"
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

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
