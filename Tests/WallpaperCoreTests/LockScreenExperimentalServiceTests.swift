import Foundation
import Testing
@testable import WallpaperCore

private struct NoopWallpaperAgentReloader: WallpaperAgentReloading {
    func reload() {}
}

@Suite("Experimental Lock Screen service")
struct LockScreenExperimentalServiceTests {
    @Test("Selects the installed Screen Saver module without changing Desktop")
    func selectsScreenSaverModule() throws {
        let temporary = try TemporaryDirectory()
        let appDirectories = AppDirectories(root: temporary.url.appendingPathComponent("App", isDirectory: true))
        let wallpaperRoot = temporary.url.appendingPathComponent("Wallpaper", isDirectory: true)
        let paths = LockScreenSystemPaths(
            index: wallpaperRoot.appendingPathComponent("Store/Index.plist"),
            entries: wallpaperRoot.appendingPathComponent("aerials/manifest/entries.json"),
            videos: wallpaperRoot.appendingPathComponent("aerials/videos", isDirectory: true),
            thumbnails: wallpaperRoot.appendingPathComponent("aerials/thumbnails", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: paths.index.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pair: [String: Any] = [
            "Desktop": ["Content": ["Choices": [["Provider": "desktop-provider"]]]],
            "Idle": ["Content": ["Choices": [["Provider": "apple-provider"]]]]
        ]
        let originalData = try PropertyListSerialization.data(
            fromPropertyList: ["AllSpacesAndDisplays": pair, "SystemDefault": pair],
            format: .binary,
            options: 0
        )
        try originalData.write(to: paths.index)
        let moduleURL = temporary.url.appendingPathComponent("Wallpaper Studio.saver", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleURL, withIntermediateDirectories: true)

        let service = LockScreenExperimentalService(
            directories: appDirectories,
            paths: paths,
            reloader: NoopWallpaperAgentReloader()
        )
        #expect(try service.activateScreenSaverModule(at: moduleURL) == 2)

        let updatedData = try Data(contentsOf: paths.index)
        let updated = try #require(
            PropertyListSerialization.propertyList(from: updatedData, format: nil) as? [String: Any]
        )
        let all = try #require(updated["AllSpacesAndDisplays"] as? [String: Any])
        let desktop = try #require(all["Desktop"] as? [String: Any])
        let desktopContent = try #require(desktop["Content"] as? [String: Any])
        let desktopChoices = try #require(desktopContent["Choices"] as? [[String: Any]])
        #expect(desktopChoices.first?["Provider"] as? String == "desktop-provider")

        let idle = try #require(all["Idle"] as? [String: Any])
        let idleContent = try #require(idle["Content"] as? [String: Any])
        let idleChoices = try #require(idleContent["Choices"] as? [[String: Any]])
        #expect(idleChoices.first?["Provider"] as? String == "com.apple.wallpaper.choice.screen-saver")
        let configuration = try #require(idleChoices.first?["Configuration"] as? Data)
        let decoded = try #require(
            PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any]
        )
        let module = try #require(decoded["module"] as? [String: String])
        #expect(module["relative"] == moduleURL.absoluteString)
    }

    @Test("Applies a personal static image to Idle without changing Desktop")
    func appliesStaticImage() throws {
        let temporary = try TemporaryDirectory()
        let appDirectories = AppDirectories(root: temporary.url.appendingPathComponent("App", isDirectory: true))
        let wallpaperRoot = temporary.url.appendingPathComponent("Wallpaper", isDirectory: true)
        let paths = LockScreenSystemPaths(
            index: wallpaperRoot.appendingPathComponent("Store/Index.plist"),
            entries: wallpaperRoot.appendingPathComponent("aerials/manifest/entries.json"),
            videos: wallpaperRoot.appendingPathComponent("aerials/videos", isDirectory: true),
            thumbnails: wallpaperRoot.appendingPathComponent("aerials/thumbnails", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: paths.index.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pair: [String: Any] = [
            "Desktop": ["Content": ["Choices": [["Provider": "desktop-provider"]]]],
            "Idle": ["Content": ["Choices": [["Provider": "default"]]]]
        ]
        let originalData = try PropertyListSerialization.data(
            fromPropertyList: ["AllSpacesAndDisplays": pair, "SystemDefault": pair],
            format: .binary,
            options: 0
        )
        try originalData.write(to: paths.index)
        let imageURL = temporary.url.appendingPathComponent("personal.jpg")
        try Data(repeating: 3, count: 64).write(to: imageURL)

        let service = LockScreenExperimentalService(
            directories: appDirectories,
            paths: paths,
            reloader: NoopWallpaperAgentReloader()
        )
        let result = try service.applyStaticImage(imageURL: imageURL)
        #expect(result.modifiedIdleNodes == 2)

        let updatedData = try Data(contentsOf: paths.index)
        let updated = try #require(
            PropertyListSerialization.propertyList(from: updatedData, format: nil) as? [String: Any]
        )
        let all = try #require(updated["AllSpacesAndDisplays"] as? [String: Any])
        let desktop = try #require(all["Desktop"] as? [String: Any])
        let desktopContent = try #require(desktop["Content"] as? [String: Any])
        let desktopChoices = try #require(desktopContent["Choices"] as? [[String: Any]])
        #expect(desktopChoices.first?["Provider"] as? String == "desktop-provider")

        let idle = try #require(all["Idle"] as? [String: Any])
        let idleContent = try #require(idle["Content"] as? [String: Any])
        let idleChoices = try #require(idleContent["Choices"] as? [[String: Any]])
        #expect(idleChoices.first?["Provider"] as? String == "com.apple.wallpaper.choice.image")
        let configuration = try #require(idleChoices.first?["Configuration"] as? Data)
        let decoded = try #require(
            PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any]
        )
        let imageLocation = try #require(decoded["url"] as? [String: String])
        #expect(imageLocation["relative"] == imageURL.absoluteString)

        try service.restore()
        #expect(try Data(contentsOf: paths.index) == originalData)
    }

    @Test("Changes only Idle and restores the exact backup")
    func appliesAndRestores() throws {
        let temporary = try TemporaryDirectory()
        let appDirectories = AppDirectories(root: temporary.url.appendingPathComponent("App", isDirectory: true))
        let wallpaperRoot = temporary.url.appendingPathComponent("Wallpaper", isDirectory: true)
        let paths = LockScreenSystemPaths(
            index: wallpaperRoot.appendingPathComponent("Store/Index.plist"),
            entries: wallpaperRoot.appendingPathComponent("aerials/manifest/entries.json"),
            videos: wallpaperRoot.appendingPathComponent("aerials/videos", isDirectory: true),
            thumbnails: wallpaperRoot.appendingPathComponent("aerials/thumbnails", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: paths.index.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.entries.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let desktopChoice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.image",
            "Files": ["desktop.jpg"],
            "Configuration": Data()
        ]
        let idleChoice: [String: Any] = [
            "Provider": "default",
            "Files": [String](),
            "Configuration": Data()
        ]
        let pair: [String: Any] = [
            "Desktop": ["Content": ["Choices": [desktopChoice]]],
            "Idle": ["Content": ["Choices": [idleChoice]]]
        ]
        let store: [String: Any] = [
            "AllSpacesAndDisplays": pair,
            "SystemDefault": pair,
            "Displays": [String: Any](),
            "Spaces": [String: Any]()
        ]
        let originalStoreData = try PropertyListSerialization.data(
            fromPropertyList: store,
            format: .binary,
            options: 0
        )
        try originalStoreData.write(to: paths.index)
        let originalEntries = Data("{\"version\":1,\"categories\":[],\"assets\":[]}".utf8)
        try originalEntries.write(to: paths.entries)

        let video = temporary.url.appendingPathComponent("prepared.mov")
        let preview = temporary.url.appendingPathComponent("poster.jpg")
        try Data(repeating: 7, count: 256).write(to: video)
        try Data(repeating: 9, count: 64).write(to: preview)

        let service = LockScreenExperimentalService(
            directories: appDirectories,
            paths: paths,
            reloader: NoopWallpaperAgentReloader()
        )
        let result = try service.apply(videoURL: video, previewURL: preview, title: "Test Video")
        #expect(result.modifiedIdleNodes == 2)
        #expect(service.hasRestorableBackup)
        #expect(try service.isAerialCarrierSelected(assetID: result.assetID))

        let updatedData = try Data(contentsOf: paths.index)
        let updated = try #require(
            PropertyListSerialization.propertyList(from: updatedData, format: nil) as? [String: Any]
        )
        let all = try #require(updated["AllSpacesAndDisplays"] as? [String: Any])
        let desktop = try #require(all["Desktop"] as? [String: Any])
        let desktopContent = try #require(desktop["Content"] as? [String: Any])
        let desktopChoices = try #require(desktopContent["Choices"] as? [[String: Any]])
        #expect(desktopChoices.first?["Provider"] as? String == "com.apple.wallpaper.choice.image")

        let idle = try #require(all["Idle"] as? [String: Any])
        let idleContent = try #require(idle["Content"] as? [String: Any])
        let idleChoices = try #require(idleContent["Choices"] as? [[String: Any]])
        #expect(idleChoices.first?["Provider"] as? String == "com.apple.wallpaper.choice.aerials")

        try service.restore()
        #expect(!service.hasRestorableBackup)
        #expect(try Data(contentsOf: paths.index) == originalStoreData)
        #expect(try Data(contentsOf: paths.entries) == originalEntries)
    }
}
