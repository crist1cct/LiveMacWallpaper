import Foundation
import Testing
@testable import WallpaperCore

@Suite("Wallpaper backend facade")
struct WallpaperBackendTests {
    @Test("Local import becomes available to an active profile")
    func importsAndActivates() async throws {
        let temporary = try TemporaryDirectory()
        let source = temporary.url.appendingPathComponent("backend.mp4")
        try Data("backend-video".utf8).write(to: source)
        let backend = try WallpaperBackend(
            directories: AppDirectories(root: temporary.url.appendingPathComponent("App")),
            mediaProcessor: FakeMediaProcessor()
        )

        let item = try await backend.importLocalFile(source)
        let profile = WallpaperProfile(
            name: "Backend",
            desktop: DestinationConfiguration(selection: .media(item.id)),
            screenSaver: DestinationConfiguration(selection: .off),
            lockScreen: DestinationConfiguration(selection: .media(item.id))
        )
        try await backend.activate(profile: profile)

        #expect(try await backend.activeConfiguration()?.activeProfile == profile)
    }
}
