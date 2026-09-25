import Foundation

/// Versões mostradas no rodapé do menu. App e pipeline são eixos distintos: o app
/// roda o Python direto do checkout, então um pull muda o pipeline sem reinstalar.
enum AppVersion {
    static var app: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Lida uma vez por abertura do app; `nil` se o script não existir ou não declarar versão.
    static let pipeline: String? = pipelineVersion(atPath: AppConfig.scriptPath)

    static var label: String {
        "v\(app)" + (pipeline.map { " · pipeline \($0)" } ?? "")
    }

    static func pipelineVersion(atPath path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return pipelineVersion(in: text)
    }

    static func pipelineVersion(in source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^PIPELINE_VERSION\s*=\s*"([^"]+)""#, options: .anchorsMatchLines),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }
}
