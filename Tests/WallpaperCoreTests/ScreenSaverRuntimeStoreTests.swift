import Foundation
import Testing
@testable import WallpaperCore

@Suite("Screen Saver runtime package")
struct ScreenSaverRuntimeStoreTests {
    @Test("Exports one selected media file and reloads its display settings")
    func roundTrip() throws {
        let temporary = try TemporaryDirectory()
        let store = ScreenSaverRuntimeStore(
            root: temporary.url.appendingPathComponent("Shared", isDirectory: true)
        )
        let source = temporary.url.appendingPathComponent("prepared.mov")
        try Data("video-content".utf8).write(to: source)
        let item = MediaItem(
            id: UUID(),
            title: "Track Preview",
            kind: .video,
            origin: .local(originalFilename: "source.mp4"),
            duration: 12,
            pixelSize: PixelSize(width: 1920, height: 1080),
            codec: "avc1",
            checksum: "checksum",
            preparedRelativePath: "prepared.mov",
            thumbnailRelativePath: "thumbnail.jpg",
            posterRelativePath: "poster.jpg"
        )

        try store.configure(
            item: item,
            sourceURL: source,
            scaling: .fit,
            displayTarget: .display("display-2")
        )

        let loaded = try store.load()
        let content = try #require(loaded)
        #expect(content.configuration.mediaKind == .video)
        #expect(content.configuration.scaling == .fit)
        #expect(content.configuration.targetDisplayIDs == ["display-2"])
        #expect(content.configuration.title == "Track Preview")
        #expect(try Data(contentsOf: content.mediaURL) == Data("video-content".utf8))

        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test("Rejects a runtime media path that escapes the shared package")
    func rejectsEscapingPath() throws {
        let temporary = try TemporaryDirectory()
        let store = ScreenSaverRuntimeStore(
            root: temporary.url.appendingPathComponent("Shared", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let invalid = ScreenSaverRuntimeConfiguration(
            mediaKind: .video,
            mediaRelativePath: "../outside.mov",
            scaling: .fill,
            targetDisplayIDs: nil,
            title: "Invalid"
        )
        let data = try JSONEncoder().encode(invalid)
        try data.write(to: store.configurationURL)

        #expect(throws: ScreenSaverRuntimeError.unsafeMediaPath) {
            _ = try store.load()
        }
    }
}
