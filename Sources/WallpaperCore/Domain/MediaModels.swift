import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image
    case video
}

public enum MediaQuality: String, Codable, CaseIterable, Sendable {
    case efficient
    case native
    case original
}

public struct PixelSize: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum MediaOrigin: Codable, Hashable, Sendable {
    case local(originalFilename: String)
    case youtube(videoID: String, webpageURL: URL, channel: String?)
}

public struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public let kind: MediaKind
    public let origin: MediaOrigin
    public let importedAt: Date
    public let duration: TimeInterval?
    public let pixelSize: PixelSize
    public let codec: String?
    public let checksum: String
    public let preparedRelativePath: String
    public let thumbnailRelativePath: String
    public let posterRelativePath: String
    public var isFavorite: Bool

    public init(
        id: UUID,
        title: String,
        kind: MediaKind,
        origin: MediaOrigin,
        importedAt: Date = .now,
        duration: TimeInterval?,
        pixelSize: PixelSize,
        codec: String?,
        checksum: String,
        preparedRelativePath: String,
        thumbnailRelativePath: String,
        posterRelativePath: String,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.origin = origin
        self.importedAt = importedAt
        self.duration = duration
        self.pixelSize = pixelSize
        self.codec = codec
        self.checksum = checksum
        self.preparedRelativePath = preparedRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.posterRelativePath = posterRelativePath
        self.isFavorite = isFavorite
    }
}

public struct LibraryManifest: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var items: [MediaItem]

    public init(
        schemaVersion: Int = LibraryManifest.currentSchemaVersion,
        items: [MediaItem] = []
    ) {
        self.schemaVersion = schemaVersion
        self.items = items
    }
}

public enum ImportPhase: Sendable, Equatable {
    case validating
    case copying
    case inspecting
    case preparing(progress: Double?)
    case generatingPreview
    case saving
}

public struct PreparedMedia: Sendable, Equatable {
    public let kind: MediaKind
    public let duration: TimeInterval?
    public let pixelSize: PixelSize
    public let codec: String?
    public let preparedFilename: String
    public let thumbnailFilename: String
    public let posterFilename: String

    public init(
        kind: MediaKind,
        duration: TimeInterval?,
        pixelSize: PixelSize,
        codec: String?,
        preparedFilename: String,
        thumbnailFilename: String,
        posterFilename: String
    ) {
        self.kind = kind
        self.duration = duration
        self.pixelSize = pixelSize
        self.codec = codec
        self.preparedFilename = preparedFilename
        self.thumbnailFilename = thumbnailFilename
        self.posterFilename = posterFilename
    }
}

