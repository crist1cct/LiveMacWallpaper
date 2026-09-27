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
            "Unsupported media file type: \(extensionName)."
        case .unreadableMedia:
            "The media file can't be read."
        case .missingVideoTrack:
            "The selected file has no video track."
        case .exportPresetUnavailable:
            "This Mac can't prepare the video at the requested quality."
        case let .exportFailed(message):
            "Video preparation failed: \(message)."
        case .fallbackTranscoderUnavailable:
            "This video format needs the bundled FFmpeg component, which is missing. Reinstall the app from the DMG."
        case .fallbackTranscodeFailed:
            "The video couldn't be converted to a format this Mac supports."
        case .previewGenerationFailed:
            "The preview couldn't be generated."
        case .invalidImage:
            "The selected image is invalid or damaged."
        }
    }
}
