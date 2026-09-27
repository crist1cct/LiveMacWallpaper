import AppKit
import CoreGraphics
import Foundation
import WallpaperCore

enum WallpaperExtensionError: Error, LocalizedError {
    case requiresTahoe
    case extensionMissing
    case extensionRegistrationFailed
    case extensionNotRegistered
    case videoRequired
    case wallpaperStoreMissing
    case invalidWallpaperStore
    case deploymentFailed
    case verificationFailed
    case noBackup

    var errorDescription: String? {
        switch self {
        case .requiresTahoe:
            "Videoclipul pe Lock Screen necesită macOS 26 Tahoe sau o versiune mai nouă."
        case .extensionMissing:
            "Extensia Wallpaper Studio pentru macOS 26 lipsește din aplicație. Reinstalează aplicația din DMG."
        case .extensionRegistrationFailed:
            "macOS nu a acceptat extensia Wallpaper Studio. Instalează aplicația semnată în dosarul Applications și deschide-o din acel dosar."
        case .extensionNotRegistered:
            "Extensia Wallpaper Studio nu este înregistrată în macOS. Închide aplicația, mut-o în Applications și deschide-o din nou."
        case .videoRequired:
            "Pentru Lock Screen trebuie selectat un videoclip."
        case .wallpaperStoreMissing:
            "Baza de date Wallpaper din macOS nu a fost găsită. Deschide o dată Setări sistem → Wallpaper."
        case .invalidWallpaperStore:
            "Configurația Wallpaper a sistemului nu poate fi citită în siguranță."
        case .deploymentFailed:
            "Videoclipul nu a putut fi pregătit pentru extensia Lock Screen."
        case .verificationFailed:
            "macOS nu a păstrat selecția Wallpaper Studio pentru Lock Screen."
        case .noBackup:
            "Nu există o configurație Apple salvată pentru restaurare."
        }
    }
}

/// Installs a real macOS 26 Wallpaper Extension selection. WallpaperAgent owns
/// the resulting surface, so it remains behind the secure authentication UI.
@MainActor
final class WallpaperExtensionService {
    static let bundleIdentifier = "com.wallpaperstudio.app.wallpaper-extension"
    static let libraryChangedNotification = "com.wallpaperstudio.wallpaper.libraryChanged"
    static let preferencesChangedNotification = "com.wallpaperstudio.wallpaper.prefsChanged"

    private struct Metadata: Codable {
        let id: String
        let name: String
        let filename: String
        let duration: Double
        let fps: Double
        let resolution: CGSize
        let dateAdded: Date
    }

    /// Must stay wire-compatible with WallpaperPrefs.PrefsFile in the extension.
    private struct Preferences: Codable {
        let userPaused: Bool
        let alwaysPauseDesktop: Bool
        let pauseWhenOccluded: Bool
        let desktopOccluded: Bool
        let occludedDisplays: Set<UInt32>?
        let fullscreenDisplays: Set<UInt32>?
        let pausedDisplays: Set<UInt32>?
        let screenSaverIsOurs: Bool?
        let lockScreenAudioEnabled: Bool?
        let lockScreenAudioVolume: Double?
        let desktopImagePath: String?
    }

    private let fileManager = FileManager.default

    private var extensionBundleURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions", isDirectory: true)
            .appendingPathComponent("WallpaperStudioWallpaperExtension.appex", isDirectory: true)
    }

    private var extensionDocumentsURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data/Documents", isDirectory: true)
    }

    private var wallpaperStoreURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private var backupURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wallpaperstudio.app/Backups", isDirectory: true)
            .appendingPathComponent("WallpaperExtension-Index.plist")
    }

    var isAvailable: Bool {
        if #available(macOS 26, *) {
            return fileManager.fileExists(atPath: extensionBundleURL.path)
        }
        return false
    }

    /// Registers the embedded provider before the user opens System Settings.
    /// WallpaperAgent does not reliably discover a newly copied app bundle until
    /// PlugInKit has been nudged, which otherwise produces “This wallpaper can't
    /// be opened” on a clean Mac even though the extension is present and signed.
    @discardableResult
    func ensureRegistered() -> Bool {
        guard #available(macOS 26, *), isAvailable,
              !Bundle.main.bundleURL.path.hasPrefix("/Volumes/")
        else { return false }
        do {
            try registerEmbeddedExtension()
            return true
        } catch {
            NSLog("[Wallpaper Studio] extension registration failed: %@", error.localizedDescription)
            return false
        }
    }

    var isSelected: Bool {
        guard let data = try? Data(contentsOf: wallpaperStoreURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return false }
        return Self.contains(Self.bundleIdentifier, in: root)
    }

    func apply(
        item: MediaItem,
        mediaURL: URL,
        posterURL: URL,
        desktopImageURL: URL?,
        configuration: DestinationConfiguration
    ) throws {
        guard #available(macOS 26, *) else { throw WallpaperExtensionError.requiresTahoe }
        guard isAvailable else { throw WallpaperExtensionError.extensionMissing }
        guard item.kind == .video, fileManager.fileExists(atPath: mediaURL.path) else {
            throw WallpaperExtensionError.videoRequired
        }
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
            throw WallpaperExtensionError.wallpaperStoreMissing
        }

        try registerEmbeddedExtension()

        try fileManager.createDirectory(at: extensionDocumentsURL, withIntermediateDirectories: true)
        let deployedVideoURL = try deploy(item: item, mediaURL: mediaURL, posterURL: posterURL)
        let retainedDesktopImage = desktopImageURL
            ?? currentSystemDesktopImageURL(for: configuration.displayTarget)
            ?? posterURL
        let deployedDesktopImageURL = try deployDesktopImage(retainedDesktopImage)
        try writePreferences(
            configuration: configuration,
            desktopImageURL: deployedDesktopImageURL
        )
        try selectExtension(
            videoID: item.id.uuidString,
            videoURL: deployedVideoURL,
            displayTarget: configuration.displayTarget
        )

        // WallpaperAgent validates the provider asynchronously. Waiting here
        // catches the exact rejection that previously produced a false success
        // banner while Tahoe silently restored the Apple image.
        Thread.sleep(forTimeInterval: 1.5)
        guard isSelected else { throw WallpaperExtensionError.verificationFailed }
        postDarwinNotification(Self.libraryChangedNotification)
        postDarwinNotification(Self.preferencesChangedNotification)
    }

    func restoreAppleWallpaper() throws {
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw WallpaperExtensionError.noBackup
        }
        freezeWallpaperAgent()
        defer { restartWallpaperServices() }
        let data = try Data(contentsOf: backupURL)
        try data.write(to: wallpaperStoreURL, options: .atomic)
    }

    private func deploy(item: MediaItem, mediaURL: URL, posterURL: URL) throws -> URL {
        let videosURL = extensionDocumentsURL.appendingPathComponent("videos", isDirectory: true)
        try fileManager.createDirectory(at: videosURL, withIntermediateDirectories: true)

        let id = item.id.uuidString
        let destination = videosURL.appendingPathComponent(id, isDirectory: true)
        let staging = videosURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let safeExtension = mediaURL.pathExtension.isEmpty ? "mov" : mediaURL.pathExtension.lowercased()
            let filename = "video.\(safeExtension)"
            let videoDestination = staging.appendingPathComponent(filename)
            try fileManager.copyItem(at: mediaURL, to: videoDestination)

            if fileManager.fileExists(atPath: posterURL.path) {
                try fileManager.copyItem(
                    at: posterURL,
                    to: staging.appendingPathComponent("thumbnail.jpg")
                )
            }

            let metadata = Metadata(
                id: id,
                name: item.title,
                filename: filename,
                duration: item.duration ?? 0,
                fps: 0,
                resolution: CGSize(width: item.pixelSize.width, height: item.pixelSize.height),
                dateAdded: item.importedAt
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(metadata).write(
                to: staging.appendingPathComponent("metadata.json"),
                options: .atomic
            )

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
            return destination.appendingPathComponent(filename)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw WallpaperExtensionError.deploymentFailed
        }
    }

    private func deployDesktopImage(_ sourceURL: URL) throws -> URL {
        let destination = extensionDocumentsURL.appendingPathComponent("desktop-image.jpg")
        let temporary = extensionDocumentsURL.appendingPathComponent(".desktop-image-\(UUID().uuidString).jpg")
        try fileManager.copyItem(at: sourceURL, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        return destination
    }

    private func currentSystemDesktopImageURL(for target: DisplayTarget) -> URL? {
        let screens = NSScreen.screens
        let screen: NSScreen?
        switch target {
        case .all:
            screen = NSScreen.main ?? screens.first
        case let .display(displayID):
            screen = screens.first { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return false
                }
                return String(number.uint32Value) == displayID
            } ?? NSScreen.main ?? screens.first
        }
        return screen.flatMap(NSWorkspace.shared.desktopImageURL(for:))
    }

    private func writePreferences(
        configuration: DestinationConfiguration,
        desktopImageURL: URL
    ) throws {
        let preferences = Preferences(
            userPaused: false,
            alwaysPauseDesktop: true,
            pauseWhenOccluded: true,
            desktopOccluded: false,
            occludedDisplays: nil,
            fullscreenDisplays: nil,
            pausedDisplays: nil,
            screenSaverIsOurs: true,
            lockScreenAudioEnabled: !configuration.muteVideo,
            lockScreenAudioVolume: min(1, max(0, configuration.volume)),
            desktopImagePath: desktopImageURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(preferences).write(
            to: extensionDocumentsURL.appendingPathComponent("wallpaperstudio-prefs.json"),
            options: .atomic
        )
    }

    private func selectExtension(
        videoID: String,
        videoURL: URL,
        displayTarget: DisplayTarget
    ) throws {
        let originalData = try Data(contentsOf: wallpaperStoreURL)
        guard var root = try PropertyListSerialization.propertyList(
            from: originalData,
            options: .mutableContainersAndLeaves,
            format: nil
        ) as? [String: Any] else {
            throw WallpaperExtensionError.invalidWallpaperStore
        }

        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: backupURL.path), !Self.contains(Self.bundleIdentifier, in: root) {
            try originalData.write(to: backupURL, options: .atomic)
        }

        let choice: [String: Any] = [
            "Provider": Self.bundleIdentifier,
            "Files": [["relative": videoURL.absoluteString]],
            "Configuration": Data(videoID.utf8)
        ]
        let options = try PropertyListSerialization.data(
            fromPropertyList: ["values": [String: Any]()],
            format: .binary,
            options: 0
        )
        let content: [String: Any] = [
            "Choices": [choice],
            "Shuffle": "$null",
            "EncodedOptionValues": options
        ]
        let linked: [String: Any] = [
            "LastSet": Date(),
            "LastUse": Date(),
            "Content": content
        ]
        let container: [String: Any] = ["Type": "linked", "Linked": linked]

        switch displayTarget {
        case .all:
            root["AllSpacesAndDisplays"] = container
            root["SystemDefault"] = container
            root["Displays"] = [String: Any]()
            root["Spaces"] = [String: Any]()
        case let .display(displayID):
            var displays = root["Displays"] as? [String: Any] ?? [:]
            displays[displayID] = container
            root["Displays"] = displays
            root = Self.replaceDisplay(
                displayID,
                with: container,
                inSpacesOf: root
            )
        }

        let output = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
        freezeWallpaperAgent()
        defer { restartWallpaperServices() }
        try output.write(to: wallpaperStoreURL, options: .atomic)
    }

    private static func replaceDisplay(
        _ displayID: String,
        with container: [String: Any],
        inSpacesOf root: [String: Any]
    ) -> [String: Any] {
        var result = root
        guard var spaces = result["Spaces"] as? [String: Any] else { return result }
        for key in spaces.keys {
            guard var space = spaces[key] as? [String: Any],
                  var displays = space["Displays"] as? [String: Any],
                  displays[displayID] != nil
            else { continue }
            displays[displayID] = container
            space["Displays"] = displays
            spaces[key] = space
        }
        result["Spaces"] = spaces
        return result
    }

    private func freezeWallpaperAgent() {
        run("/usr/bin/killall", ["-STOP", "WallpaperAgent"])
    }

    private func registerEmbeddedExtension() throws {
        guard !Bundle.main.bundleURL.path.hasPrefix("/Volumes/") else {
            throw WallpaperExtensionError.extensionRegistrationFailed
        }

        // Keep an already valid registration intact. Removing and re-adding a
        // provider on every launch can leave a development-only PlugInKit
        // record without version metadata. If the app was moved or upgraded,
        // the explicit add below refreshes the path without disturbing a valid
        // provider that WallpaperAgent is already using.
        let (_, existing) = runOutput(
            "/usr/bin/pluginkit",
            ["-m", "-A", "-v", "-i", Self.bundleIdentifier]
        )
        if existing.contains(extensionBundleURL.path) {
            _ = run("/usr/bin/pluginkit", ["-e", "use", "-i", Self.bundleIdentifier])
            return
        }

        let addStatus = run("/usr/bin/pluginkit", ["-a", extensionBundleURL.path])
        guard addStatus == 0 else { throw WallpaperExtensionError.extensionRegistrationFailed }

        let electionStatus = run("/usr/bin/pluginkit", ["-e", "use", "-i", Self.bundleIdentifier])
        guard electionStatus == 0 else { throw WallpaperExtensionError.extensionRegistrationFailed }

        // Registration is serviced asynchronously by pkd. Poll briefly so the
        // subsequent wallpaper-store write cannot race the provider discovery.
        for _ in 0..<8 {
            let (status, output) = runOutput(
                "/usr/bin/pluginkit",
                ["-m", "-A", "-v", "-i", Self.bundleIdentifier]
            )
            if status == 0, output.contains(extensionBundleURL.path) {
                Thread.sleep(forTimeInterval: 0.2)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw WallpaperExtensionError.extensionNotRegistered
    }

    private func restartWallpaperServices() {
        run("/usr/bin/killall", ["-KILL", "WallpaperAgent"])
        run("/usr/bin/killall", ["-KILL", "WallpaperStudioWallpaperExtension"])
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func runOutput(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func postDarwinNotification(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    private static func contains(_ expected: String, in value: Any) -> Bool {
        if let string = value as? String { return string == expected }
        if let data = value as? Data,
           let nested = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            return contains(expected, in: nested)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { contains(expected, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { contains(expected, in: $0) }
        }
        return false
    }
}
