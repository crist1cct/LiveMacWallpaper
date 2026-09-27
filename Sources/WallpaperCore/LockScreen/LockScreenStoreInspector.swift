import Foundation

public struct LockScreenCompatibilityReport: Sendable, Equatable {
    public let operatingSystemMajorVersion: Int
    public let storeExists: Bool
    public let desktopAndIdlePairCount: Int
    public let isKnownStructure: Bool
    public let canAttemptExperimentalIntegration: Bool
    public let reasons: [String]

    public init(
        operatingSystemMajorVersion: Int,
        storeExists: Bool,
        desktopAndIdlePairCount: Int,
        isKnownStructure: Bool,
        canAttemptExperimentalIntegration: Bool,
        reasons: [String]
    ) {
        self.operatingSystemMajorVersion = operatingSystemMajorVersion
        self.storeExists = storeExists
        self.desktopAndIdlePairCount = desktopAndIdlePairCount
        self.isKnownStructure = isKnownStructure
        self.canAttemptExperimentalIntegration = canAttemptExperimentalIntegration
        self.reasons = reasons
    }
}

public struct LockScreenStoreInspector: Sendable {
    public init() {}

    public static func defaultStoreURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    public func inspect(
        storeURL: URL = Self.defaultStoreURL(),
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> LockScreenCompatibilityReport {
        let major = operatingSystemVersion.majorVersion
        let knownVersion = major == 15 || major == 26
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return LockScreenCompatibilityReport(
                operatingSystemMajorVersion: major,
                storeExists: false,
                desktopAndIdlePairCount: 0,
                isKnownStructure: false,
                canAttemptExperimentalIntegration: false,
                reasons: ["The macOS wallpaper store does not exist yet."]
            )
        }

        do {
            let data = try Data(contentsOf: storeURL)
            let value = try PropertyListSerialization.propertyList(from: data, format: nil)
            let pairCount = Self.desktopAndIdlePairCount(in: value)
            var reasons: [String] = []
            if !knownVersion {
                reasons.append("This macOS major version has not been validated.")
            }
            if pairCount == 0 {
                reasons.append("No separate Desktop and Idle nodes were found.")
            }
            return LockScreenCompatibilityReport(
                operatingSystemMajorVersion: major,
                storeExists: true,
                desktopAndIdlePairCount: pairCount,
                isKnownStructure: pairCount > 0,
                canAttemptExperimentalIntegration: knownVersion && pairCount > 0,
                reasons: reasons
            )
        } catch {
            return LockScreenCompatibilityReport(
                operatingSystemMajorVersion: major,
                storeExists: true,
                desktopAndIdlePairCount: 0,
                isKnownStructure: false,
                canAttemptExperimentalIntegration: false,
                reasons: ["The wallpaper store is not a readable property list."]
            )
        }
    }

    private static func desktopAndIdlePairCount(in value: Any) -> Int {
        if let dictionary = value as? [String: Any] {
            var count = dictionary["Desktop"] != nil && dictionary["Idle"] != nil ? 1 : 0
            for child in dictionary.values {
                count += desktopAndIdlePairCount(in: child)
            }
            return count
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + desktopAndIdlePairCount(in: $1) }
        }
        return 0
    }
}
