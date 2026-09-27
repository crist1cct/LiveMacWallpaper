import Foundation

public enum WallpaperDestination: String, Codable, CaseIterable, Hashable, Sendable {
    case desktop
    case screenSaver
    case lockScreen
}

public enum ContentScaling: String, Codable, CaseIterable, Sendable {
    case fill
    case fit
    case stretch
}

/// A stable, unambiguous display destination stored in every profile.
/// Display IDs are Core Graphics UUIDs and survive display reordering.
public enum DisplayTarget: Codable, Hashable, Sendable {
    case all
    case display(String)

    public var explicitDisplayID: String? {
        guard case let .display(id) = self else { return nil }
        return id
    }

    public var legacyDisplayIDs: Set<String>? {
        switch self {
        case .all: nil
        case let .display(id): [id]
        }
    }

    public init(legacyDisplayIDs: Set<String>?) {
        guard let id = legacyDisplayIDs?.sorted().first else {
            self = .all
            return
        }
        self = .display(id)
    }
}

public enum DestinationSelection: Codable, Hashable, Sendable {
    case systemDefault
    case media(UUID)
    case follow(WallpaperDestination)
    case off
}

public struct DestinationConfiguration: Codable, Hashable, Sendable {
    public var selection: DestinationSelection
    public var scaling: ContentScaling
    /// Additional scale applied after the selected fill/fit/stretch mode.
    public var zoom: Double
    /// Normalized horizontal placement from -1 (left) to 1 (right).
    public var horizontalPosition: Double
    /// Normalized vertical placement from -1 (bottom) to 1 (top).
    public var verticalPosition: Double
    public var muteVideo: Bool
    public var volume: Double
    public var displayTarget: DisplayTarget
    public var pauseInLowPowerMode: Bool

    public init(
        selection: DestinationSelection,
        scaling: ContentScaling = .fill,
        zoom: Double = 1,
        horizontalPosition: Double = 0,
        verticalPosition: Double = 0,
        muteVideo: Bool = true,
        volume: Double = 0.5,
        targetDisplayIDs: Set<String>? = nil,
        pauseInLowPowerMode: Bool = true
    ) {
        self.selection = selection
        self.scaling = scaling
        self.zoom = Self.clamp(zoom, to: 0.5...3)
        self.horizontalPosition = Self.clamp(horizontalPosition, to: -1...1)
        self.verticalPosition = Self.clamp(verticalPosition, to: -1...1)
        self.muteVideo = muteVideo
        self.volume = Self.clamp(volume, to: 0...1)
        self.displayTarget = DisplayTarget(legacyDisplayIDs: targetDisplayIDs)
        self.pauseInLowPowerMode = pauseInLowPowerMode
    }

    /// Compatibility bridge for schema 1 call sites. New code should use `displayTarget`.
    public var targetDisplayIDs: Set<String>? {
        get { displayTarget.legacyDisplayIDs }
        set { displayTarget = DisplayTarget(legacyDisplayIDs: newValue) }
    }

    private enum CodingKeys: String, CodingKey {
        case selection
        case scaling
        case zoom
        case horizontalPosition
        case verticalPosition
        case muteVideo
        case volume
        case displayTarget
        case targetDisplayIDs
        case pauseInLowPowerMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selection = try container.decode(DestinationSelection.self, forKey: .selection)
        scaling = try container.decodeIfPresent(ContentScaling.self, forKey: .scaling) ?? .fill
        zoom = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1, to: 0.5...3)
        horizontalPosition = Self.clamp(
            try container.decodeIfPresent(Double.self, forKey: .horizontalPosition) ?? 0,
            to: -1...1
        )
        verticalPosition = Self.clamp(
            try container.decodeIfPresent(Double.self, forKey: .verticalPosition) ?? 0,
            to: -1...1
        )
        muteVideo = try container.decodeIfPresent(Bool.self, forKey: .muteVideo) ?? true
        volume = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5, to: 0...1)
        if let decodedTarget = try container.decodeIfPresent(DisplayTarget.self, forKey: .displayTarget) {
            displayTarget = decodedTarget
        } else {
            let legacyIDs = try container.decodeIfPresent(Set<String>.self, forKey: .targetDisplayIDs)
            displayTarget = DisplayTarget(legacyDisplayIDs: legacyIDs)
        }
        pauseInLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selection, forKey: .selection)
        try container.encode(scaling, forKey: .scaling)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(horizontalPosition, forKey: .horizontalPosition)
        try container.encode(verticalPosition, forKey: .verticalPosition)
        try container.encode(muteVideo, forKey: .muteVideo)
        try container.encode(volume, forKey: .volume)
        try container.encode(displayTarget, forKey: .displayTarget)
        try container.encode(pauseInLowPowerMode, forKey: .pauseInLowPowerMode)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

public struct WallpaperProfile: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var desktop: DestinationConfiguration
    public var screenSaver: DestinationConfiguration
    public var lockScreen: DestinationConfiguration

    public init(
        id: UUID = UUID(),
        name: String,
        desktop: DestinationConfiguration = .init(selection: .systemDefault),
        screenSaver: DestinationConfiguration = .init(selection: .follow(.desktop)),
        lockScreen: DestinationConfiguration = .init(selection: .systemDefault)
    ) {
        self.id = id
        self.name = name
        self.desktop = desktop
        self.screenSaver = screenSaver
        self.lockScreen = lockScreen
    }

    public subscript(destination: WallpaperDestination) -> DestinationConfiguration {
        get {
            switch destination {
            case .desktop: desktop
            case .screenSaver: screenSaver
            case .lockScreen: lockScreen
            }
        }
        set {
            switch destination {
            case .desktop: desktop = newValue
            case .screenSaver: screenSaver = newValue
            case .lockScreen: lockScreen = newValue
            }
        }
    }
}

public enum ProfileValidationError: Error, Equatable, LocalizedError {
    case followCycle([WallpaperDestination])
    case missingMedia(UUID)

    public var errorDescription: String? {
        switch self {
        case .followCycle:
            "The destination configuration contains a follow cycle."
        case let .missingMedia(id):
            "The selected media item no longer exists: \(id.uuidString)."
        }
    }
}

public struct ProfileValidator: Sendable {
    public init() {}

    public func validate(_ profile: WallpaperProfile, availableMediaIDs: Set<UUID>) throws {
        for destination in WallpaperDestination.allCases {
            try resolve(destination, profile: profile, visited: [], availableMediaIDs: availableMediaIDs)
        }
    }

    public func resolvedSelection(
        for destination: WallpaperDestination,
        in profile: WallpaperProfile,
        availableMediaIDs: Set<UUID>
    ) throws -> DestinationSelection {
        try resolve(destination, profile: profile, visited: [], availableMediaIDs: availableMediaIDs)
    }

    @discardableResult
    private func resolve(
        _ destination: WallpaperDestination,
        profile: WallpaperProfile,
        visited: [WallpaperDestination],
        availableMediaIDs: Set<UUID>
    ) throws -> DestinationSelection {
        if visited.contains(destination) {
            throw ProfileValidationError.followCycle(visited + [destination])
        }

        let selection = profile[destination].selection
        switch selection {
        case let .media(id):
            guard availableMediaIDs.contains(id) else {
                throw ProfileValidationError.missingMedia(id)
            }
            return selection
        case let .follow(other):
            return try resolve(
                other,
                profile: profile,
                visited: visited + [destination],
                availableMediaIDs: availableMediaIDs
            )
        case .systemDefault, .off:
            return selection
        }
    }
}

public struct RuntimeConfiguration: Codable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let generatedAt: Date
    public let activeProfile: WallpaperProfile

    public init(
        schemaVersion: Int = RuntimeConfiguration.currentSchemaVersion,
        generatedAt: Date = .now,
        activeProfile: WallpaperProfile
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.activeProfile = activeProfile
    }
}
