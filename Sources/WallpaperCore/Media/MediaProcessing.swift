import Foundation

public protocol MediaProcessing: Sendable {
    func prepare(
        sourceURL: URL,
        kind: MediaKind,
        outputDirectory: URL,
        quality: MediaQuality,
        progress: @escaping @Sendable (ImportPhase) -> Void
    ) async throws -> PreparedMedia
}

public enum MediaProcessingError: Error, Equatable, LocalizedError {
    case unsupportedFileType(String)
    case unreadableMedia
    case missingVideoTrack
    case exportPresetUnavailable
    case exportFailed(String)
    case fallbackTranscoderUnavailable
    case fallbackTranscodeFailed
    case previewGenerationFailed
    case invalidImage

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFileType(extensionName):
            "Tipul de fișier media nu este acceptat: \(extensionName)."
        case .unreadableMedia:
            "Fișierul media nu poate fi citit."
        case .missingVideoTrack:
            "Fișierul selectat nu conține o pistă video."
        case .exportPresetUnavailable:
            "Acest Mac nu poate pregăti videoclipul la calitatea solicitată."
        case let .exportFailed(message):
            "Pregătirea videoclipului a eșuat: \(message)."
        case .fallbackTranscoderUnavailable:
            "Formatul video necesită componenta de compatibilitate FFmpeg, dar aceasta lipsește din aplicație. Reinstalează aplicația din DMG."
        case .fallbackTranscodeFailed:
            "Videoclipul nu a putut fi convertit într-un format compatibil cu acest Mac."
        case .previewGenerationFailed:
            "Previzualizarea nu a putut fi generată."
        case .invalidImage:
            "Imaginea selectată este invalidă sau deteriorată."
        }
    }
}
