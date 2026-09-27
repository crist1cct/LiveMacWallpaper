import Foundation
@testable import WallpaperCore

final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperStudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

struct FakeMediaProcessor: MediaProcessing {
    func prepare(
        sourceURL: URL,
        kind: MediaKind,
        outputDirectory: URL,
        quality: MediaQuality,
        progress: @escaping @Sendable (ImportPhase) -> Void
    ) async throws -> PreparedMedia {
        progress(.inspecting)
        let prepared = outputDirectory.appendingPathComponent("prepared.mov")
        let thumbnail = outputDirectory.appendingPathComponent("thumbnail.jpg")
        let poster = outputDirectory.appendingPathComponent("poster.jpg")
        try Data("prepared".utf8).write(to: prepared)
        try Data("thumbnail".utf8).write(to: thumbnail)
        try Data("poster".utf8).write(to: poster)
        return PreparedMedia(
            kind: kind,
            duration: kind == .video ? 12 : nil,
            pixelSize: PixelSize(width: 1920, height: 1080),
            codec: kind == .video ? "hvc1" : nil,
            preparedFilename: prepared.lastPathComponent,
            thumbnailFilename: thumbnail.lastPathComponent,
            posterFilename: poster.lastPathComponent
        )
    }
}

struct FixedHelperLocator: YouTubeHelperLocating {
    let url: URL?

    func executableURL() -> URL? { url }
}

struct FixedFFmpegLocator: YouTubeFFmpegLocating {
    let url: URL?

    func executableURL() -> URL? { url }
}

actor FakeYouTubeRunner: CommandRunning {
    private(set) var calls: [[String]] = []
    var metadataData: Data
    var failureCode: Int32

    init(metadataData: Data, failureCode: Int32 = 0) {
        self.metadataData = metadataData
        self.failureCode = failureCode
    }

    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?
    ) async throws -> CommandResult {
        calls.append(arguments)
        if arguments == ["--version"] {
            return CommandResult(
                exitCode: failureCode,
                standardOutput: failureCode == 0 ? Data("2026.08.19\n".utf8) : Data(),
                standardError: failureCode == 0 ? Data() : Data("version failed".utf8)
            )
        }
        if arguments.contains("--dump-single-json") {
            return CommandResult(
                exitCode: failureCode,
                standardOutput: metadataData,
                standardError: failureCode == 0 ? Data() : Data("metadata failed".utf8)
            )
        }

        if let currentDirectoryURL {
            try Data("fake-video".utf8).write(
                to: currentDirectoryURL.appendingPathComponent("youtube-source.mp4")
            )
        }
        return CommandResult(exitCode: failureCode, standardOutput: Data(), standardError: Data())
    }
}

let validYouTubeMetadata = Data(
    """
    {
      "id": "dQw4w9WgXcQ",
      "title": "Sample Wallpaper",
      "channel": "Sample Channel",
      "duration": 42.5,
      "thumbnail": "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg",
      "webpage_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    }
    """.utf8
)
