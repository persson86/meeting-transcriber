import Foundation

/// Centralized app paths. Override them via UserDefaults without recompiling:
///   defaults write <bundle-id> projectRoot /path/to/meeting-transcriber
///   defaults write <bundle-id> pythonPath /path/to/python
///   defaults write <bundle-id> scriptPath /path/to/transcribe_meeting.py
///   defaults write <bundle-id> defaultOutputDirectory /path/to/output
///   defaults write <bundle-id> contextTerms -array "ProjectName" "CustomerName"
///   defaults write <bundle-id> maxConcurrentTranscriptions 2
///   defaults write <bundle-id> secondBrainPath /path/to/second-brain
enum AppConfig {
    static var projectRoot: String {
        if let configured = UserDefaults.standard.string(forKey: "projectRoot"), !configured.isEmpty {
            return NSString(string: configured).expandingTildeInPath
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            FileManager.default.currentDirectoryPath,
            "\(home)/meeting-transcriber",
            "\(home)/Projects/meeting-transcriber",
            "\(home)/Developer/meeting-transcriber"
        ]

        for candidate in candidates {
            let script = URL(fileURLWithPath: candidate).appendingPathComponent("transcribe_meeting.py")
            if FileManager.default.fileExists(atPath: script.path) {
                return candidate
            }
        }

        return "\(home)/meeting-transcriber"
    }

    static var pythonPath: String {
        if let configured = UserDefaults.standard.string(forKey: "pythonPath"), !configured.isEmpty {
            return NSString(string: configured).expandingTildeInPath
        }
        return projectRoot + "/.venv/bin/python"
    }

    static var scriptPath: String {
        if let configured = UserDefaults.standard.string(forKey: "scriptPath"), !configured.isEmpty {
            return NSString(string: configured).expandingTildeInPath
        }
        return projectRoot + "/transcribe_meeting.py"
    }

    static var defaultOutputDirectory: URL {
        if let configured = UserDefaults.standard.string(forKey: "defaultOutputDirectory"), !configured.isEmpty {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Transcriptions")
    }

    static var contextTerms: [String] {
        if let values = UserDefaults.standard.array(forKey: "contextTerms") as? [String] {
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let raw = UserDefaults.standard.string(forKey: "contextTerms") {
            return raw.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    static var maxConcurrentTranscriptions: Int {
        let value = UserDefaults.standard.integer(forKey: "maxConcurrentTranscriptions")
        guard value > 0 else { return 1 }
        return min(value, 3)
    }

    /// Pasta raiz do second-brain. Se não setada, a integração fica invisível na UI.
    static var secondBrainPath: String? {
        guard let configured = UserDefaults.standard.string(forKey: "secondBrainPath"),
              !configured.isEmpty else { return nil }
        return NSString(string: configured).expandingTildeInPath
    }

    // MARK: - Modelo de transcrição (memória)

    /// Modelo MLX menor para o modo de baixa memória. Multilíngue (bom p/ PT-BR),
    /// decoder podado — ~metade da memória/tempo do large-v3 fp16 com perda mínima.
    static let lowMemoryMlxModel = "mlx-community/whisper-large-v3-turbo"

    /// Override explícito do modelo MLX. nil = usa o default da CLI (large-v3 fp16).
    ///   defaults write <bundle-id> mlxModel mlx-community/whisper-large-v3-turbo
    static var mlxModel: String? {
        guard let v = UserDefaults.standard.string(forKey: "mlxModel"), !v.isEmpty else { return nil }
        return v
    }

    /// Override explícito do backend. nil = default da CLI (mlx).
    static var transcriptionBackend: String? {
        guard let v = UserDefaults.standard.string(forKey: "transcriptionBackend"), !v.isEmpty else { return nil }
        return v
    }

    /// Modo de baixa memória: sem um mlxModel explícito, aponta para o modelo menor.
    ///   defaults write <bundle-id> lowMemoryMode -bool YES
    static var lowMemoryMode: Bool {
        UserDefaults.standard.bool(forKey: "lowMemoryMode")
    }

    /// Modelo MLX efetivo passado à CLI: override explícito > low-memory > default da CLI (nil).
    static var effectiveMlxModel: String? {
        if let m = mlxModel { return m }
        if lowMemoryMode { return lowMemoryMlxModel }
        return nil
    }

    /// Liga logs de diagnóstico de memória no lado Swift (PID, tamanhos, concorrência).
    ///   defaults write <bundle-id> debugMemoryLogging -bool YES
    static var debugMemoryLogging: Bool {
        UserDefaults.standard.bool(forKey: "debugMemoryLogging")
    }
}
