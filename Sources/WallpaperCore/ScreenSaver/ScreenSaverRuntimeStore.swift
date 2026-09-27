import Darwin
import Foundation

public struct ScreenSaverRuntimeConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let mediaKind: MediaKind
    public let mediaRelativePath: String
    public let scaling: ContentScaling
    public let zoom: Double
    public let horizontalPosition: Double
    public let verticalPosition: Double
    public let muteVideo: Bool
    public let volume: Double
    public let displayTarget: DisplayTarget
    public let title: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        mediaKind: MediaKind,
        mediaRelativePath: String,
        scaling: ContentScaling,
        zoom: Double = 1,
        horizontalPosition: Double = 0,
        verticalPosition: Double = 0,
        muteVideo: Bool = true,
        volume: Double = 0.5,
        targetDisplayIDs: Set<String>?,
        title: String
    ) {
        self.schemaVersion = schemaVersion
        self.mediaKind = mediaKind
        self.mediaRelativePath = mediaRelativePath
        self.scaling = scaling
        self.zoom = zoom
        self.horizontalPosition = horizontalPosition
        self.verticalPosition = verticalPosition
        self.muteVideo = muteVideo
        self.volume = volume
        self.displayTarget = DisplayTarget(legacyDisplayIDs: targetDisplayIDs)
        self.title = title
    }

    public var targetDisplayIDs: Set<String>? { displayTarget.legacyDisplayIDs }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mediaKind
        case mediaRelativePath
        case scaling
        case zoom
        case horizontalPosition
        case verticalPosition
        case muteVideo
        case volume
        case displayTarget
        case targetDisplayIDs
        case title
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        mediaKind = try container.decode(MediaKind.self, forKey: .mediaKind)
        mediaRelativePath = try container.decode(String.self, forKey: .mediaRelativePath)
        scaling = try container.decodeIfPresent(ContentScaling.self, forKey: .scaling) ?? .fill
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        horizontalPosition = try container.decodeIfPresent(Double.self, forKey: .horizontalPosition) ?? 0
        verticalPosition = try container.decodeIfPresent(Double.self, forKey: .verticalPosition) ?? 0
        muteVideo = try container.decodeIfPresent(Bool.self, forKey: .muteVideo) ?? true
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5
        if let decodedTarget = try container.decodeIfPresent(DisplayTarget.self, forKey: .displayTarget) {
            displayTarget = decodedTarget
        } else {
            displayTarget = DisplayTarget(
                legacyDisplayIDs: try container.decodeIfPresent(Set<String>.self, forKey: .targetDisplayIDs)
            )
        }
        title = try container.decode(String.self, forKey: .title)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mediaKind, forKey: .mediaKind)
        try container.encode(mediaRelativePath, forKey: .mediaRelativePath)
        try container.encode(scaling, forKey: .scaling)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(horizontalPosition, forKey: .horizontalPosition)
        try container.encode(verticalPosition, forKey: .verticalPosition)
        try container.encode(muteVideo, forKey: .muteVideo)
        try container.encode(volume, forKey: .volume)
        try container.encode(displayTarget, forKey: .displayTarget)
        try container.encode(title, forKey: .title)
    }
}

public struct ScreenSaverRuntimeContent: Equatable, Sendable {
    public let configuration: ScreenSaverRuntimeConfiguration
    public let mediaURL: URL
}

public enum ScreenSaverRuntimeError: Error, Equatable, LocalizedError {
    case missingMedia
    case unsupportedSchema(Int)
    case unsafeMediaPath

    public var errorDescription: String? {
        switch self {
        case .missingMedia:
            "Conținutul pentru Screen Saver nu a fost găsit. Aplică din nou configurația."
        case let .unsupportedSchema(schema):
            "Configurația Screen Saver nu este compatibilă (versiunea \(schema))."
        case .unsafeMediaPath:
            "Calea conținutului Screen Saver nu este sigură."
        }
    }
}

/// A deliberately small, read-only-at-playback package in `/Users/Shared`.
/// Modern macOS runs legacy `.saver` bundles inside an Apple sandbox, so they
/// cannot read Wallpaper Studio's normal Application Support directory.
public struct ScreenSaverRuntimeStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func sharedForCurrentUser() -> ScreenSaverRuntimeStore {
        ScreenSaverRuntimeStore(
            root: URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
                .appendingPathComponent("Wallpaper Studio", isDirectory: true)
                .appendingPathComponent(String(getuid()), isDirectory: true)
                .appendingPathComponent("Screen Saver", isDirectory: true)
        )
    }

    public var configurationURL: URL {
        root.appendingPathComponent("Current.json")
    }

    public func configure(
        item: MediaItem,
        sourceURL: URL,
        scaling: ContentScaling,
        zoom: Double = 1,
        horizontalPosition: Double = 0,
        verticalPosition: Double = 0,
        muteVideo: Bool = true,
        volume: Double = 0.5,
        displayTarget: DisplayTarget
    ) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ScreenSaverRuntimeError.missingMedia
        }

        try prepareDirectories()
        let extensionName = Self.safeExtension(
            sourceURL.pathExtension,
            fallback: item.kind == .video ? "mov" : "jpg"
        )
        let relativePath = "Media/\(item.id.uuidString)/content.\(extensionName)"
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.setReadableDirectory(destination.deletingLastPathComponent())
        try Self.atomicCopy(sourceURL, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: destination.path
        )

        let configuration = ScreenSaverRuntimeConfiguration(
            mediaKind: item.kind,
            mediaRelativePath: relativePath,
            scaling: scaling,
            zoom: zoom,
            horizontalPosition: horizontalPosition,
            verticalPosition: verticalPosition,
            muteVideo: muteVideo,
            volume: volume,
            targetDisplayIDs: displayTarget.legacyDisplayIDs,
            title: item.title
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        try data.write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: configurationURL.path
        )
    }

    public func load() throws -> ScreenSaverRuntimeContent? {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: configurationURL)
        let configuration = try JSONDecoder().decode(
            ScreenSaverRuntimeConfiguration.self,
            from: data
        )
        guard (1...ScreenSaverRuntimeConfiguration.currentSchemaVersion).contains(configuration.schemaVersion) else {
            throw ScreenSaverRuntimeError.unsupportedSchema(configuration.schemaVersion)
        }
        guard !configuration.mediaRelativePath.hasPrefix("/") else {
            throw ScreenSaverRuntimeError.unsafeMediaPath
        }

        let mediaURL = root
            .appendingPathComponent(configuration.mediaRelativePath)
            .standardizedFileURL
        let rootPath = root.standardizedFileURL.path + "/"
        guard mediaURL.path.hasPrefix(rootPath) else {
            throw ScreenSaverRuntimeError.unsafeMediaPath
        }
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw ScreenSaverRuntimeError.missingMedia
        }
        return ScreenSaverRuntimeContent(configuration: configuration, mediaURL: mediaURL)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else { return }
        try FileManager.default.removeItem(at: configurationURL)
    }

    private func prepareDirectories() throws {
        let userRoot = root.deletingLastPathComponent()
        var directories = [userRoot, root, root.appendingPathComponent("Media", isDirectory: true)]
        let commonRoot = userRoot.deletingLastPathComponent().standardizedFileURL
        if commonRoot.path == "/Users/Shared/Wallpaper Studio" {
            directories.insert(commonRoot, at: 0)
        }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.setReadableDirectory(directory)
        }
    }

    private static func atomicCopy(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private static func setReadableDirectory(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private static func safeExtension(_ value: String, fallback: String) -> String {
        let lowercased = value.lowercased()
        guard !lowercased.isEmpty,
              lowercased.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        else {
            return fallback
        }
        return lowercased
    }
}
