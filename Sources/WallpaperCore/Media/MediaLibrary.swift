import Foundation
import UniformTypeIdentifiers

public enum MediaLibraryError: Error, Equatable, LocalizedError {
    case unsupportedManifestSchema(Int)
    case unsupportedFileType(String)
    case duplicateMedia(existingID: UUID)
    case itemNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedManifestSchema(schema):
            "Unsupported media library schema: \(schema)."
        case let .unsupportedFileType(extensionName):
            "Unsupported file type: \(extensionName)."
        case let .duplicateMedia(existingID):
            "This media is already in the library: \(existingID.uuidString)."
        case let .itemNotFound(id):
            "The media item was not found: \(id.uuidString)."
        }
    }
}

public actor MediaLibrary {
    private let directories: AppDirectories
    private let processor: any MediaProcessing
    private var manifest: LibraryManifest

    public init(
        directories: AppDirectories,
        processor: any MediaProcessing = NativeMediaProcessor()
    ) throws {
        self.directories = directories
        self.processor = processor
        try directories.prepare()

        if FileManager.default.fileExists(atPath: directories.manifest.path) {
            let data = try Data(contentsOf: directories.manifest)
            let decoded = try AtomicJSON.decoder.decode(LibraryManifest.self, from: data)
            guard decoded.schemaVersion == LibraryManifest.currentSchemaVersion else {
                throw MediaLibraryError.unsupportedManifestSchema(decoded.schemaVersion)
            }
            self.manifest = decoded
        } else {
            self.manifest = LibraryManifest()
        }
    }

    public func allItems() -> [MediaItem] {
        manifest.items.sorted { $0.importedAt > $1.importedAt }
    }

    public func item(id: UUID) -> MediaItem? {
        manifest.items.first { $0.id == id }
    }

    public func preparedURL(for item: MediaItem) -> URL {
        directories.itemDirectory(id: item.id).appendingPathComponent(item.preparedRelativePath)
    }

    public func thumbnailURL(for item: MediaItem) -> URL {
        directories.itemDirectory(id: item.id).appendingPathComponent(item.thumbnailRelativePath)
    }

    public func posterURL(for item: MediaItem) -> URL {
        directories.itemDirectory(id: item.id).appendingPathComponent(item.posterRelativePath)
    }

    public func importLocalFile(
        _ sourceURL: URL,
        title: String? = nil,
        origin: MediaOrigin? = nil,
        quality: MediaQuality = .efficient,
        progress: @escaping @Sendable (ImportPhase) -> Void = { _ in }
    ) async throws -> MediaItem {
        progress(.validating)
        let kind = try Self.kind(for: sourceURL)
        let checksum = try FileChecksum.sha256(of: sourceURL)

        if let existing = manifest.items.first(where: { $0.checksum == checksum }) {
            throw MediaLibraryError.duplicateMedia(existingID: existing.id)
        }

        let id = UUID()
        let itemDirectory = directories.itemDirectory(id: id)
        try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)

        do {
            progress(.copying)
            let sourceExtension = Self.safeExtension(sourceURL.pathExtension, fallback: "media")
            let copiedSource = itemDirectory.appendingPathComponent("source.\(sourceExtension)")
            try FileManager.default.copyItem(at: sourceURL, to: copiedSource)

            let prepared = try await processor.prepare(
                sourceURL: copiedSource,
                kind: kind,
                outputDirectory: itemDirectory,
                quality: quality,
                progress: progress
            )

            progress(.saving)
            let item = MediaItem(
                id: id,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? sourceURL.deletingPathExtension().lastPathComponent,
                kind: prepared.kind,
                origin: origin ?? .local(originalFilename: sourceURL.lastPathComponent),
                duration: prepared.duration,
                pixelSize: prepared.pixelSize,
                codec: prepared.codec,
                checksum: checksum,
                preparedRelativePath: prepared.preparedFilename,
                thumbnailRelativePath: prepared.thumbnailFilename,
                posterRelativePath: prepared.posterFilename
            )
            manifest.items.append(item)
            try persist()
            return item
        } catch {
            try? FileManager.default.removeItem(at: itemDirectory)
            throw error
        }
    }

    public func rename(id: UUID, title: String) throws {
        guard let index = manifest.items.firstIndex(where: { $0.id == id }) else {
            throw MediaLibraryError.itemNotFound(id)
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manifest.items[index].title = trimmed
        try persist()
    }

    public func setFavorite(id: UUID, isFavorite: Bool) throws {
        guard let index = manifest.items.firstIndex(where: { $0.id == id }) else {
            throw MediaLibraryError.itemNotFound(id)
        }
        manifest.items[index].isFavorite = isFavorite
        try persist()
    }

    public func remove(id: UUID) throws {
        guard let index = manifest.items.firstIndex(where: { $0.id == id }) else {
            throw MediaLibraryError.itemNotFound(id)
        }

        let originalManifest = manifest
        manifest.items.remove(at: index)
        do {
            try persist()
            try FileManager.default.removeItem(at: directories.itemDirectory(id: id))
        } catch {
            manifest = originalManifest
            try? persist()
            throw error
        }
    }

    private func persist() throws {
        try AtomicJSON.write(manifest, to: directories.manifest)
    }

    private static func kind(for url: URL) throws -> MediaKind {
        let extensionName = url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: extensionName) else {
            throw MediaLibraryError.unsupportedFileType(extensionName)
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        if type.conforms(to: .image) {
            return .image
        }
        throw MediaLibraryError.unsupportedFileType(extensionName)
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
