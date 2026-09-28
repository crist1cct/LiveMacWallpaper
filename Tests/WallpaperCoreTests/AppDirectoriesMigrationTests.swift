import Foundation
import Testing
@testable import WallpaperCore

@Suite("Library migration after rename")
struct AppDirectoriesMigrationTests {
    @Test("A library under the previous bundle identifier is moved to the new one")
    func movesLegacyLibrary() throws {
        let temporary = try TemporaryDirectory()
        let legacy = temporary.url.appendingPathComponent(AppDirectories.legacyBundleIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("Library.json"))

        let root = temporary.url.appendingPathComponent("com.livemacwallpaper.app", isDirectory: true)
        AppDirectories.migrateLegacyLibrary(to: root, base: temporary.url, fileManager: .default)

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library.json").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("An existing library is never overwritten")
    func keepsExistingLibrary() throws {
        let temporary = try TemporaryDirectory()
        let legacy = temporary.url.appendingPathComponent(AppDirectories.legacyBundleIdentifier, isDirectory: true)
        let root = temporary.url.appendingPathComponent("com.livemacwallpaper.app", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: root.appendingPathComponent("Library.json"))

        AppDirectories.migrateLegacyLibrary(to: root, base: temporary.url, fileManager: .default)

        #expect(try String(contentsOf: root.appendingPathComponent("Library.json"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }
}
