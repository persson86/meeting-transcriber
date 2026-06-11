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
}
