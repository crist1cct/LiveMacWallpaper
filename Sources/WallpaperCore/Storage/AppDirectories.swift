import Foundation

public struct AppDirectories: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Bundle identifier used before the project was renamed to Live Mac Wallpaper.
    public static let legacyBundleIdentifier = "com.wallpaperstudio.app"

    public static func applicationSupport(
        bundleIdentifier: String = "com.livemacwallpaper.app",
        fileManager: FileManager = .default
    ) throws -> AppDirectories {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
        migrateLegacyLibrary(to: root, base: base, fileManager: fileManager)
        return AppDirectories(root: root)
    }

    /// One-time move of a library created under the previous bundle identifier.
    /// Items store relative paths, so the whole directory can be moved as-is.
    /// Nothing happens when the new location already exists.
    static func migrateLegacyLibrary(to root: URL, base: URL, fileManager: FileManager) {
        let legacy = base.appendingPathComponent(legacyBundleIdentifier, isDirectory: true)
        guard legacy.standardizedFileURL != root.standardizedFileURL,
              !fileManager.fileExists(atPath: root.path),
              fileManager.fileExists(atPath: legacy.path)
        else { return }
        try? fileManager.moveItem(at: legacy, to: root)
    }

    public var media: URL { root.appendingPathComponent("Media", isDirectory: true) }
    public var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    public var runtime: URL { root.appendingPathComponent("Runtime", isDirectory: true) }
    public var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    public var manifest: URL { root.appendingPathComponent("Library.json") }
    public var activeConfiguration: URL { runtime.appendingPathComponent("Current.json") }
    public var lockScreenState: URL { runtime.appendingPathComponent("LockScreenState.json") }
    public var aerialLockScreenState: URL { runtime.appendingPathComponent("AerialLockScreenState.json") }

    public func itemDirectory(id: UUID) -> URL {
        media.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func prepare(fileManager: FileManager = .default) throws {
        for directory in [root, media, staging, runtime, backups] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

enum AtomicJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
