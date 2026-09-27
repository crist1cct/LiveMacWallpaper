import Foundation
import Testing
@testable import WallpaperCore

@Suite("Media library")
struct MediaLibraryTests {
    @Test("Imports, persists, and removes a media item")
    func libraryLifecycle() async throws {
        let temporary = try TemporaryDirectory()
        let source = temporary.url.appendingPathComponent("wallpaper.mp4")
        try Data("source-video".utf8).write(to: source)
        let directories = AppDirectories(root: temporary.url.appendingPathComponent("Library"))
        let library = try MediaLibrary(directories: directories, processor: FakeMediaProcessor())

        let item = try await library.importLocalFile(source, quality: .efficient)
        #expect(item.title == "wallpaper")
        #expect(item.kind == .video)
        #expect(FileManager.default.fileExists(atPath: await library.preparedURL(for: item).path))

        let reloaded = try MediaLibrary(directories: directories, processor: FakeMediaProcessor())
        #expect(await reloaded.allItems().map(\.id) == [item.id])

        try await reloaded.remove(id: item.id)
        #expect(await reloaded.allItems().isEmpty)
    }

    @Test("Duplicate content is rejected")
    func duplicateDetection() async throws {
        let temporary = try TemporaryDirectory()
        let source = temporary.url.appendingPathComponent("same.mp4")
        try Data("same-video".utf8).write(to: source)
        let library = try MediaLibrary(
            directories: AppDirectories(root: temporary.url.appendingPathComponent("Library")),
            processor: FakeMediaProcessor()
        )

        let first = try await library.importLocalFile(source)
        await #expect(throws: MediaLibraryError.duplicateMedia(existingID: first.id)) {
            try await library.importLocalFile(source)
        }
    }
}

