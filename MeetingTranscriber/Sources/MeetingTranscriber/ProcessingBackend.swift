import Foundation
import Security

/// Onde roda o ASR (2.3). A escolha é global nas Configurações e fica gravada
/// em cada job no enfileiramento: trocar depois não muda o que já está na fila.
enum ProcessingBackend: String, CaseIterable {
    case local
    case groq

    /// Mesma chave do override antigo por `defaults write`; "groq" liga a nuvem,
    /// qualquer outro valor (ou nenhum) é local.
    static let defaultsKey = "transcriptionBackend"
    static let groqKeychainService = "meeting-transcriber-groq"
    static let groqModel = "whisper-large-v3"

    static func stored(in defaults: UserDefaults = .standard) -> ProcessingBackend {
        defaults.string(forKey: defaultsKey) == ProcessingBackend.groq.rawValue ? .groq : .local
    }

    /// Valor gravado no job; manifests antigos e valores desconhecidos são locais.
    init(jobValue: String?) {
        self = jobValue == ProcessingBackend.groq.rawValue ? .groq : .local
    }

    var label: String {
        switch self {
        case .local: return "Local"
        case .groq: return "Groq API"
        }
    }

    /// Argumentos do pipeline. Groq leva o consentimento por execução que a CLI
    /// exige; local respeita um override antigo de backend local (mlx/faster-whisper).
    func pipelineArguments(localOverride: String? = AppConfig.transcriptionBackend) -> [String] {
        switch self {
        case .groq:
            return ["--backend", "groq", "--allow-cloud-asr", "--groq-model", Self.groqModel]
        case .local:
            guard let override = localOverride, override == "mlx" || override == "faster-whisper" else { return [] }
            return ["--backend", override]
        }
    }

    /// Existe chave na env ou no Keychain? Só confere a presença do item, sem
    /// ler o segredo (o pipeline lê via `security` na hora do job).
    static func groqKeyAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let value = environment["GROQ_API_KEY"], !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: groqKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
