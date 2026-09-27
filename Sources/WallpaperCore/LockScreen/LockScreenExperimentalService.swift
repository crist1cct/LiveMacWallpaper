import Foundation

public struct LockScreenSystemPaths: Sendable {
    public let index: URL
    public let entries: URL
    public let videos: URL
    public let thumbnails: URL

    public init(index: URL, entries: URL, videos: URL, thumbnails: URL) {
        self.index = index
        self.entries = entries
        self.videos = videos
        self.thumbnails = thumbnails
    }

    public static func currentUser(fileManager: FileManager = .default) -> LockScreenSystemPaths {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper", isDirectory: true)
        return LockScreenSystemPaths(
            index: root.appendingPathComponent("Store/Index.plist"),
            entries: root.appendingPathComponent("aerials/manifest/entries.json"),
            videos: root.appendingPathComponent("aerials/videos", isDirectory: true),
            thumbnails: root.appendingPathComponent("aerials/thumbnails", isDirectory: true)
        )
    }
}

public protocol WallpaperAgentReloading: Sendable {
    func reload()
}

public struct DefaultWallpaperAgentReloader: WallpaperAgentReloading {
    public init() {}

    public func reload() {
        for name in ["WallpaperAgent", "WallpaperVideoExtension", "WallpaperAerialsExtension"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            // SIGTERM gives WallpaperAgent time to flush its stale in-memory
            // store over the Index.plist we just wrote. SIGKILL prevents that
            // write-back; launchd then starts a fresh agent which reads the
            // updated Idle selection from disk.
            process.arguments = ["-KILL", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}

public struct LockScreenApplyResult: Sendable, Equatable {
    public let assetID: String
    public let modifiedIdleNodes: Int
    public let backupDirectory: URL

    public init(assetID: String, modifiedIdleNodes: Int, backupDirectory: URL) {
        self.assetID = assetID
        self.modifiedIdleNodes = modifiedIdleNodes
        self.backupDirectory = backupDirectory
    }
}

public enum LockScreenIntegrationError: Error, Equatable, LocalizedError {
    case incompatibleSystem([String])
    case missingMedia
    case unreadableStore
    case noIdleNodes
    case invalidManifest
    case verificationFailed
    case noBackup
    case damagedBackup

    public var errorDescription: String? {
        switch self {
        case let .incompatibleSystem(reasons):
            "Lock Screen video is unavailable: \(reasons.joined(separator: " "))"
        case .missingMedia:
            "The prepared video or preview is missing."
        case .unreadableStore:
            "The macOS wallpaper store could not be read safely."
        case .noIdleNodes:
            "No independent Lock Screen configuration was found."
        case .invalidManifest:
            "The macOS Aerial manifest could not be updated safely."
        case .verificationFailed:
            "macOS did not retain the new Lock Screen configuration. The backup was restored."
        case .noBackup:
            "There is no Wallpaper Studio Lock Screen backup to restore."
        case .damagedBackup:
            "The Lock Screen backup failed its integrity check."
        }
    }
}

public struct LockScreenExperimentalService: @unchecked Sendable {
    private static let categoryID = "57545354-5544-494F-8000-000000000001"
    private static let subcategoryID = "57545354-5544-494F-8000-000000000002"

    private let directories: AppDirectories
    private let paths: LockScreenSystemPaths
    private let inspector: LockScreenStoreInspector
    private let reloader: any WallpaperAgentReloading
    private let fileManager: FileManager

    public init(
        directories: AppDirectories,
        paths: LockScreenSystemPaths = .currentUser(),
        inspector: LockScreenStoreInspector = LockScreenStoreInspector(),
        reloader: any WallpaperAgentReloading = DefaultWallpaperAgentReloader(),
        fileManager: FileManager = .default
    ) {
        self.directories = directories
        self.paths = paths
        self.inspector = inspector
        self.reloader = reloader
        self.fileManager = fileManager
    }

    public var hasRestorableBackup: Bool {
        fileManager.fileExists(atPath: directories.lockScreenState.path)
    }

    public var hasAerialCarrierBackup: Bool {
        fileManager.fileExists(atPath: directories.aerialLockScreenState.path)
    }

    /// Selects a legacy ScreenSaver bundle in the modern wallpaper store.
    /// macOS 15/26 no longer reads `com.apple.screensaver.moduleDict` as the
    /// source of truth; the selected module lives in each Idle node instead.
    /// Desktop nodes are intentionally left untouched.
    @discardableResult
    public func activateScreenSaverModule(at moduleURL: URL) throws -> Int {
        guard fileManager.fileExists(atPath: moduleURL.path),
              moduleURL.pathExtension.lowercased() == "saver"
        else {
            throw LockScreenIntegrationError.missingMedia
        }
        let report = inspector.inspect(storeURL: paths.index)
        guard report.canAttemptExperimentalIntegration else {
            throw LockScreenIntegrationError.incompatibleSystem(report.reasons)
        }

        // If Aerial was selected temporarily for native Lock Screen, return to
        // its exact pre-Aerial store before selecting the Screen Saver module.
        if hasAerialCarrierBackup {
            try restoreAerialCarrierIndex()
        }

        let originalData = try Data(contentsOf: paths.index)
        do {
            let modifiedCount = try updateIdleStore(screenSaverModuleURL: moduleURL)
            guard modifiedCount > 0 else {
                throw LockScreenIntegrationError.noIdleNodes
            }
            guard try verifyScreenSaverModule(moduleURL) else {
                throw LockScreenIntegrationError.verificationFailed
            }
            reloader.reload()
            return modifiedCount
        } catch {
            try? Self.atomicWrite(originalData, to: paths.index)
            throw error
        }
    }

    public func isAerialCarrierSelected(assetID: String) throws -> Bool {
        try verifyStoreContains(assetID.uppercased())
    }

    /// Selects a genuine Apple Aerial identifier only for the Idle branch. The
    /// Desktop branch is deliberately left untouched. The privileged carrier
    /// installer owns the corresponding video file and its system-level backup.
    public func applyAerialCarrier(assetID: String) throws -> LockScreenApplyResult {
        guard UUID(uuidString: assetID) != nil else {
            throw LockScreenIntegrationError.invalidManifest
        }
        let report = inspector.inspect(storeURL: paths.index)
        guard report.canAttemptExperimentalIntegration else {
            throw LockScreenIntegrationError.incompatibleSystem(report.reasons)
        }
        if hasAerialCarrierBackup {
            try restoreAerialCarrierIndex()
        }

        try directories.prepare(fileManager: fileManager)
        let backupDirectory = directories.backups
            .appendingPathComponent("AerialCarrier-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let indexBackup = backupDirectory.appendingPathComponent("Index.plist")
        try fileManager.copyItem(at: paths.index, to: indexBackup)
        let state = AerialCarrierBackupState(
            schemaVersion: 1,
            assetID: assetID.uppercased(),
            backupDirectory: backupDirectory,
            indexHash: try FileChecksum.sha256(of: indexBackup)
        )

        do {
            let modifiedCount = try updateIdleStore(assetID: state.assetID)
            guard modifiedCount > 0 else {
                throw LockScreenIntegrationError.noIdleNodes
            }
            try AtomicJSON.write(state, to: directories.aerialLockScreenState)
            guard try verifyStoreContains(state.assetID) else {
                throw LockScreenIntegrationError.verificationFailed
            }
            reloader.reload()
            return LockScreenApplyResult(
                assetID: state.assetID,
                modifiedIdleNodes: modifiedCount,
                backupDirectory: backupDirectory
            )
        } catch {
            try? Self.atomicCopy(indexBackup, to: paths.index, fileManager: fileManager)
            try? fileManager.removeItem(at: directories.aerialLockScreenState)
            throw error
        }
    }

    public func restoreAerialCarrierIndex() throws {
        guard fileManager.fileExists(atPath: directories.aerialLockScreenState.path) else {
            throw LockScreenIntegrationError.noBackup
        }
        let data = try Data(contentsOf: directories.aerialLockScreenState)
        let state = try AtomicJSON.decoder.decode(AerialCarrierBackupState.self, from: data)
        let indexBackup = state.backupDirectory.appendingPathComponent("Index.plist")
        guard fileManager.fileExists(atPath: indexBackup.path),
              try FileChecksum.sha256(of: indexBackup) == state.indexHash
        else {
            throw LockScreenIntegrationError.damagedBackup
        }
        try Self.atomicCopy(indexBackup, to: paths.index, fileManager: fileManager)
        try fileManager.removeItem(at: directories.aerialLockScreenState)
        reloader.reload()
    }

    public func apply(videoURL: URL, previewURL: URL, title: String) throws -> LockScreenApplyResult {
        guard fileManager.fileExists(atPath: videoURL.path),
              fileManager.fileExists(atPath: previewURL.path)
        else {
            throw LockScreenIntegrationError.missingMedia
        }

        let report = inspector.inspect(storeURL: paths.index)
        guard report.canAttemptExperimentalIntegration else {
            throw LockScreenIntegrationError.incompatibleSystem(report.reasons)
        }

        if hasRestorableBackup {
            try restore()
        }

        try directories.prepare(fileManager: fileManager)
        let backupDirectory = directories.backups
            .appendingPathComponent("LockScreen-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let indexBackup = backupDirectory.appendingPathComponent("Index.plist")
        try fileManager.copyItem(at: paths.index, to: indexBackup)
        let indexHash = try FileChecksum.sha256(of: indexBackup)

        var entriesExisted = false
        var entriesHash: String?
        let entriesBackup = backupDirectory.appendingPathComponent("entries.json")
        if fileManager.fileExists(atPath: paths.entries.path) {
            entriesExisted = true
            try fileManager.copyItem(at: paths.entries, to: entriesBackup)
            entriesHash = try FileChecksum.sha256(of: entriesBackup)
        }

        let assetID = UUID().uuidString.uppercased()
        let videoDestination = paths.videos.appendingPathComponent("\(assetID).mov")
        let previewExtension = Self.safeExtension(previewURL.pathExtension, fallback: "jpg")
        let previewDestination = paths.thumbnails.appendingPathComponent("\(assetID).\(previewExtension)")

        let state = LockScreenBackupState(
            schemaVersion: 1,
            createdAt: .now,
            assetID: assetID,
            backupDirectory: backupDirectory,
            indexHash: indexHash,
            entriesExisted: entriesExisted,
            entriesHash: entriesHash,
            videoDestination: videoDestination,
            previewDestination: previewDestination
        )

        do {
            try fileManager.createDirectory(at: paths.videos, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: paths.thumbnails, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: paths.entries.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.atomicCopy(videoURL, to: videoDestination, fileManager: fileManager)
            try Self.atomicCopy(previewURL, to: previewDestination, fileManager: fileManager)

            try updateManifest(
                assetID: assetID,
                title: title,
                videoURL: videoDestination,
                previewURL: previewDestination
            )
            let modifiedCount = try updateIdleStore(assetID: assetID)
            guard modifiedCount > 0 else {
                throw LockScreenIntegrationError.noIdleNodes
            }

            try AtomicJSON.write(state, to: directories.lockScreenState)
            guard try verify(assetID: assetID) else {
                throw LockScreenIntegrationError.verificationFailed
            }
            reloader.reload()
            return LockScreenApplyResult(
                assetID: assetID,
                modifiedIdleNodes: modifiedCount,
                backupDirectory: backupDirectory
            )
        } catch {
            try? restoreFiles(from: state)
            try? fileManager.removeItem(at: directories.lockScreenState)
            throw error
        }
    }

    public func applyStaticImage(imageURL: URL) throws -> LockScreenApplyResult {
        guard fileManager.fileExists(atPath: imageURL.path) else {
            throw LockScreenIntegrationError.missingMedia
        }
        let report = inspector.inspect(storeURL: paths.index)
        guard report.canAttemptExperimentalIntegration else {
            throw LockScreenIntegrationError.incompatibleSystem(report.reasons)
        }
        if hasRestorableBackup {
            try restore()
        }

        try directories.prepare(fileManager: fileManager)
        let backupDirectory = directories.backups
            .appendingPathComponent("LockScreen-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let indexBackup = backupDirectory.appendingPathComponent("Index.plist")
        try fileManager.copyItem(at: paths.index, to: indexBackup)

        var entriesExisted = false
        var entriesHash: String?
        let entriesBackup = backupDirectory.appendingPathComponent("entries.json")
        if fileManager.fileExists(atPath: paths.entries.path) {
            entriesExisted = true
            try fileManager.copyItem(at: paths.entries, to: entriesBackup)
            entriesHash = try FileChecksum.sha256(of: entriesBackup)
        }

        let state = LockScreenBackupState(
            schemaVersion: 1,
            createdAt: .now,
            assetID: imageURL.absoluteString,
            backupDirectory: backupDirectory,
            indexHash: try FileChecksum.sha256(of: indexBackup),
            entriesExisted: entriesExisted,
            entriesHash: entriesHash,
            videoDestination: nil,
            previewDestination: nil
        )

        do {
            let modifiedCount = try updateIdleStore(imageURL: imageURL)
            guard modifiedCount > 0 else {
                throw LockScreenIntegrationError.noIdleNodes
            }
            try AtomicJSON.write(state, to: directories.lockScreenState)
            guard try verifyStoreContains(imageURL.absoluteString) else {
                throw LockScreenIntegrationError.verificationFailed
            }
            reloader.reload()
            return LockScreenApplyResult(
                assetID: imageURL.absoluteString,
                modifiedIdleNodes: modifiedCount,
                backupDirectory: backupDirectory
            )
        } catch {
            try? restoreFiles(from: state)
            try? fileManager.removeItem(at: directories.lockScreenState)
            throw error
        }
    }

    public func restore() throws {
        guard fileManager.fileExists(atPath: directories.lockScreenState.path) else {
            throw LockScreenIntegrationError.noBackup
        }
        let data = try Data(contentsOf: directories.lockScreenState)
        let state = try AtomicJSON.decoder.decode(LockScreenBackupState.self, from: data)
        try restoreFiles(from: state)
        try fileManager.removeItem(at: directories.lockScreenState)
        reloader.reload()
    }

    private func restoreFiles(from state: LockScreenBackupState) throws {
        let indexBackup = state.backupDirectory.appendingPathComponent("Index.plist")
        guard fileManager.fileExists(atPath: indexBackup.path),
              try FileChecksum.sha256(of: indexBackup) == state.indexHash
        else {
            throw LockScreenIntegrationError.damagedBackup
        }
        try Self.atomicCopy(indexBackup, to: paths.index, fileManager: fileManager)

        let entriesBackup = state.backupDirectory.appendingPathComponent("entries.json")
        if state.entriesExisted {
            guard fileManager.fileExists(atPath: entriesBackup.path),
                  let expectedHash = state.entriesHash,
                  try FileChecksum.sha256(of: entriesBackup) == expectedHash
            else {
                throw LockScreenIntegrationError.damagedBackup
            }
            try Self.atomicCopy(entriesBackup, to: paths.entries, fileManager: fileManager)
        } else if fileManager.fileExists(atPath: paths.entries.path) {
            try fileManager.removeItem(at: paths.entries)
        }

        if let videoDestination = state.videoDestination {
            try? fileManager.removeItem(at: videoDestination)
        }
        if let previewDestination = state.previewDestination {
            try? fileManager.removeItem(at: previewDestination)
        }
    }

    private func updateManifest(assetID: String, title: String, videoURL: URL, previewURL: URL) throws {
        var root: [String: Any]
        if fileManager.fileExists(atPath: paths.entries.path) {
            let data = try Data(contentsOf: paths.entries)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LockScreenIntegrationError.invalidManifest
            }
            root = decoded
        } else {
            root = ["version": 1, "categories": [[String: Any]](), "assets": [[String: Any]]()]
        }

        var categories = root["categories"] as? [[String: Any]] ?? []
        var assets = root["assets"] as? [[String: Any]] ?? []
        categories.removeAll { $0["id"] as? String == Self.categoryID }
        assets.removeAll { asset in
            (asset["categories"] as? [String])?.contains(Self.categoryID) == true
        }

        categories.append([
            "id": Self.categoryID,
            "localizedNameKey": "Wallpaper Studio",
            "localizedDescriptionKey": "Personal Lock Screen videos",
            "preferredOrder": 999,
            "representativeAssetID": assetID,
            "previewImage": previewURL.absoluteString,
            "subcategories": [[
                "id": Self.subcategoryID,
                "localizedNameKey": "Wallpaper Studio",
                "localizedDescriptionKey": "Personal Lock Screen videos",
                "preferredOrder": 0,
                "previewImage": previewURL.absoluteString,
                "representativeAssetID": assetID
            ]]
        ])

        assets.append([
            "id": assetID,
            "localizedNameKey": title,
            "accessibilityLabel": title,
            "shotID": "WALLPAPER_STUDIO_CUSTOM",
            "showInTopLevel": true,
            "includeInShuffle": false,
            "preferredOrder": 0,
            "categories": [Self.categoryID],
            "subcategories": [Self.subcategoryID],
            "url-4K-SDR-240FPS": videoURL.absoluteString,
            "previewImage": previewURL.absoluteString,
            "pointsOfInterest": ["0": "WALLPAPER_STUDIO_0"]
        ])

        root["categories"] = categories
        root["assets"] = assets
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try Self.atomicWrite(data, to: paths.entries)
    }

    private func updateIdleStore(assetID: String) throws -> Int {
        let data = try Data(contentsOf: paths.index)
        guard let root = try PropertyListSerialization.propertyList(
            from: data,
            options: .mutableContainersAndLeaves,
            format: nil
        ) as? [String: Any]
        else {
            throw LockScreenIntegrationError.unreadableStore
        }

        let configuration = try PropertyListSerialization.data(
            fromPropertyList: [
                "assetID": assetID,
                "selectedID": assetID,
                "showAsScreenSaver": true
            ],
            format: .binary,
            options: 0
        )
        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [String](),
            "Configuration": configuration
        ]

        let result = Self.replacingIdleChoices(in: root, with: choice, encodedOptionValues: nil)
        guard let updated = result.value as? [String: Any] else {
            throw LockScreenIntegrationError.unreadableStore
        }
        let output = try PropertyListSerialization.data(
            fromPropertyList: updated,
            format: .binary,
            options: 0
        )
        try Self.atomicWrite(output, to: paths.index)
        return result.count
    }

    private func updateIdleStore(screenSaverModuleURL: URL) throws -> Int {
        let data = try Data(contentsOf: paths.index)
        guard let root = try PropertyListSerialization.propertyList(
            from: data,
            options: .mutableContainersAndLeaves,
            format: nil
        ) as? [String: Any]
        else {
            throw LockScreenIntegrationError.unreadableStore
        }

        let configuration = try PropertyListSerialization.data(
            fromPropertyList: [
                "module": ["relative": screenSaverModuleURL.absoluteString]
            ],
            format: .binary,
            options: 0
        )
        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.screen-saver",
            "Files": [String](),
            "Configuration": configuration
        ]
        let result = Self.replacingIdleChoices(in: root, with: choice, encodedOptionValues: nil)
        guard let updated = result.value as? [String: Any] else {
            throw LockScreenIntegrationError.unreadableStore
        }
        let output = try PropertyListSerialization.data(
            fromPropertyList: updated,
            format: .binary,
            options: 0
        )
        try Self.atomicWrite(output, to: paths.index)
        return result.count
    }

    private func updateIdleStore(imageURL: URL) throws -> Int {
        let data = try Data(contentsOf: paths.index)
        guard let root = try PropertyListSerialization.propertyList(
            from: data,
            options: .mutableContainersAndLeaves,
            format: nil
        ) as? [String: Any]
        else {
            throw LockScreenIntegrationError.unreadableStore
        }

        let configuration = try PropertyListSerialization.data(
            fromPropertyList: [
                "type": "imageFile",
                "url": ["relative": imageURL.absoluteString]
            ],
            format: .binary,
            options: 0
        )
        let encodedOptions = try PropertyListSerialization.data(
            fromPropertyList: [
                "values": [
                    "placement": [
                        "picker": ["_0": ["id": "Crop"]]
                    ]
                ]
            ],
            format: .binary,
            options: 0
        )
        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.image",
            "Files": [String](),
            "Configuration": configuration
        ]
        let result = Self.replacingIdleChoices(
            in: root,
            with: choice,
            encodedOptionValues: encodedOptions
        )
        guard let updated = result.value as? [String: Any] else {
            throw LockScreenIntegrationError.unreadableStore
        }
        let output = try PropertyListSerialization.data(
            fromPropertyList: updated,
            format: .binary,
            options: 0
        )
        try Self.atomicWrite(output, to: paths.index)
        return result.count
    }

    private func verify(assetID: String) throws -> Bool {
        guard fileManager.fileExists(atPath: paths.index.path),
              fileManager.fileExists(atPath: paths.entries.path),
              fileManager.fileExists(atPath: paths.videos.appendingPathComponent("\(assetID).mov").path)
        else {
            return false
        }
        let storeHasAsset = try verifyStoreContains(assetID)
        let manifestData = try Data(contentsOf: paths.entries)
        return storeHasAsset && manifestData.range(of: Data(assetID.utf8)) != nil
    }

    private func verifyStoreContains(_ expected: String) throws -> Bool {
        let data = try Data(contentsOf: paths.index)
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        return Self.contains(expected, in: root)
    }

    private func verifyScreenSaverModule(_ expectedURL: URL) throws -> Bool {
        let data = try Data(contentsOf: paths.index)
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        return Self.contains("com.apple.wallpaper.choice.screen-saver", in: root)
            && Self.contains(expectedURL.absoluteString, in: root)
    }

    private static func contains(_ expected: String, in value: Any) -> Bool {
        if let string = value as? String {
            return string == expected
        }
        if let data = value as? Data,
           let nested = try? PropertyListSerialization.propertyList(from: data, format: nil)
        {
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

    private static func replacingIdleChoices(
        in value: Any,
        with choice: [String: Any],
        encodedOptionValues: Data?
    ) -> (value: Any, count: Int) {
        if var dictionary = value as? [String: Any] {
            var count = 0
            if var idle = dictionary["Idle"] as? [String: Any] {
                var content = idle["Content"] as? [String: Any] ?? [:]
                content["Choices"] = [choice]
                if let encodedOptionValues {
                    content["EncodedOptionValues"] = encodedOptionValues
                }
                idle["Content"] = content
                idle["LastSet"] = Date()
                idle["LastUse"] = Date()
                dictionary["Idle"] = idle
                count += 1
            }

            for key in Array(dictionary.keys) {
                let child = replacingIdleChoices(
                    in: dictionary[key] as Any,
                    with: choice,
                    encodedOptionValues: encodedOptionValues
                )
                dictionary[key] = child.value
                count += child.count
            }
            return (dictionary, count)
        }
        if let array = value as? [Any] {
            var count = 0
            let updated = array.map { element -> Any in
                let child = replacingIdleChoices(
                    in: element,
                    with: choice,
                    encodedOptionValues: encodedOptionValues
                )
                count += child.count
                return child.value
            }
            return (updated, count)
        }
        return (value, 0)
    }

    private static func atomicCopy(_ source: URL, to destination: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
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

private struct LockScreenBackupState: Codable {
    let schemaVersion: Int
    let createdAt: Date
    let assetID: String
    let backupDirectory: URL
    let indexHash: String
    let entriesExisted: Bool
    let entriesHash: String?
    let videoDestination: URL?
    let previewDestination: URL?
}

private struct AerialCarrierBackupState: Codable {
    let schemaVersion: Int
    let assetID: String
    let backupDirectory: URL
    let indexHash: String
}
