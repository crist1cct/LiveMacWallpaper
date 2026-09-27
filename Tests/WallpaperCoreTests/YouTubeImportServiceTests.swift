import Foundation
import Testing
@testable import WallpaperCore

@Suite("YouTube import service")
struct YouTubeImportServiceTests {
    @Test("Reports the helper version for UX readiness")
    func reportsHelperStatus() async {
        let service = YouTubeImportService(
            commandRunner: FakeYouTubeRunner(metadataData: validYouTubeMetadata),
            helperLocator: FixedHelperLocator(url: URL(fileURLWithPath: "/fake/yt-dlp"))
        )

        #expect(await service.helperStatus() == .ready(version: "2026.08.19"))
    }

    @Test("Reads metadata using isolated yt-dlp arguments")
    func readsMetadata() async throws {
        let runner = FakeYouTubeRunner(metadataData: validYouTubeMetadata)
        let service = YouTubeImportService(
            commandRunner: runner,
            helperLocator: FixedHelperLocator(url: URL(fileURLWithPath: "/fake/yt-dlp")),
            ffmpegLocator: FixedFFmpegLocator(url: URL(fileURLWithPath: "/fake/ffmpeg"))
        )

        let metadata = try await service.inspect("https://youtu.be/dQw4w9WgXcQ")
        #expect(metadata.title == "Sample Wallpaper")
        #expect(metadata.channel == "Sample Channel")

        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls[0].contains("--ignore-config"))
        #expect(calls[0].contains("--no-playlist"))
        #expect(calls[0].last == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test("Requires explicit rights confirmation before download")
    func requiresRightsConfirmation() async throws {
        let temporary = try TemporaryDirectory()
        let runner = FakeYouTubeRunner(metadataData: validYouTubeMetadata)
        let service = YouTubeImportService(
            commandRunner: runner,
            helperLocator: FixedHelperLocator(url: URL(fileURLWithPath: "/fake/yt-dlp")),
            ffmpegLocator: FixedFFmpegLocator(url: URL(fileURLWithPath: "/fake/ffmpeg"))
        )

        await #expect(throws: YouTubeImportError.rightsConfirmationRequired) {
            try await service.download(
                "https://youtu.be/dQw4w9WgXcQ",
                to: temporary.url,
                rightsConfirmation: MediaRightsConfirmation(acceptedVersion: 0)
            )
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test("Downloads one regular MP4 file")
    func downloadsSingleVideo() async throws {
        let temporary = try TemporaryDirectory()
        let runner = FakeYouTubeRunner(metadataData: validYouTubeMetadata)
        let service = YouTubeImportService(
            commandRunner: runner,
            helperLocator: FixedHelperLocator(url: URL(fileURLWithPath: "/fake/yt-dlp")),
            ffmpegLocator: FixedFFmpegLocator(url: URL(fileURLWithPath: "/fake/ffmpeg"))
        )

        let result = try await service.download(
            "https://youtu.be/dQw4w9WgXcQ",
            to: temporary.url,
            rightsConfirmation: .confirmedNow()
        )
        #expect(result.fileURL.lastPathComponent == "youtube-source.mp4")
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))

        let calls = await runner.calls
        let downloadArguments = try #require(calls.last)
        #expect(downloadArguments.contains("bestvideo*+bestaudio/best"))
        #expect(downloadArguments.contains("res,fps,hdr:12,vbr,abr"))
        #expect(downloadArguments.contains("--merge-output-format"))
        #expect(downloadArguments.contains("/fake/ffmpeg"))
        #expect(!downloadArguments.contains("bestvideo[ext=mp4][vcodec^=avc1]/best[ext=mp4][vcodec^=avc1]"))
    }

    @Test("Keeps maximum video quality when the merge helper is unavailable")
    func downloadsBestVideoWithoutMergeHelper() async throws {
        let temporary = try TemporaryDirectory()
        let runner = FakeYouTubeRunner(metadataData: validYouTubeMetadata)
        let service = YouTubeImportService(
            commandRunner: runner,
            helperLocator: FixedHelperLocator(url: URL(fileURLWithPath: "/fake/yt-dlp")),
            ffmpegLocator: FixedFFmpegLocator(url: nil)
        )

        _ = try await service.download(
            "https://youtu.be/dQw4w9WgXcQ",
            to: temporary.url,
            rightsConfirmation: .confirmedNow()
        )

        let calls = await runner.calls
        let downloadArguments = try #require(calls.last)
        #expect(downloadArguments.contains("bestvideo*/best"))
        #expect(!downloadArguments.contains("--merge-output-format"))
    }
}
