import Foundation

public actor WallpaperBackend {
    public nonisolated let directories: AppDirectories
    public let library: MediaLibrary

    private let runtimeStore: RuntimeConfigurationStore
    private let youtubeImporter: YouTubeImportService
    private let lockScreenInspector: LockScreenStoreInspector
    private let lockScreenService: LockScreenExperimentalService

    public init(
        directories: AppDirectories,
        mediaProcessor: any MediaProcessing = NativeMediaProcessor(),
        youtubeImporter: YouTubeImportService = YouTubeImportService(),
        lockScreenInspector: LockScreenStoreInspector = LockScreenStoreInspector(),
        lockScreenService: LockScreenExperimentalService? = nil
    ) throws {
        try directories.prepare()
        self.directories = directories
        self.library = try MediaLibrary(directories: directories, processor: mediaProcessor)
        self.runtimeStore = RuntimeConfigurationStore(directories: directories)
        self.youtubeImporter = youtubeImporter
        self.lockScreenInspector = lockScreenInspector
        self.lockScreenService = lockScreenService ?? LockScreenExperimentalService(directories: directories)
    }

    public static func live() throws -> WallpaperBackend {
        try WallpaperBackend(directories: AppDirectories.applicationSupport())
    }

    public func mediaItems() async -> [MediaItem] {
        await library.allItems()
    }

    public func mediaURLs(for item: MediaItem) async -> (prepared: URL, thumbnail: URL, poster: URL) {
        await (
            library.preparedURL(for: item),
            library.thumbnailURL(for: item),
            library.posterURL(for: item)
        )
    }

    public func renameMedia(id: UUID, title: String) async throws {
        try await library.rename(id: id, title: title)
    }

    public func setFavorite(id: UUID, isFavorite: Bool) async throws {
        try await library.setFavorite(id: id, isFavorite: isFavorite)
    }

    public func removeMedia(id: UUID) async throws {
        try await library.remove(id: id)
    }

    public func importLocalFile(
        _ url: URL,
        quality: MediaQuality = .efficient,
        progress: @escaping @Sendable (ImportPhase) -> Void = { _ in }
    ) async throws -> MediaItem {
        try await library.importLocalFile(url, quality: quality, progress: progress)
    }

    public func inspectYouTubeURL(_ rawURL: String) async throws -> YouTubeMetadata {
        try await youtubeImporter.inspect(rawURL)
    }

    public func youtubeHelperStatus() async -> YouTubeHelperStatus {
        await youtubeImporter.helperStatus()
    }

    public func importYouTubeVideo(
        _ rawURL: String,
        rightsConfirmation: MediaRightsConfirmation,
        quality: MediaQuality = .original,
        progress: @escaping @Sendable (YouTubeImportPhase) -> Void = { _ in }
    ) async throws -> MediaItem {
        try await youtubeImporter.importIntoLibrary(
            rawURL,
            library: library,
            directories: directories,
            rightsConfirmation: rightsConfirmation,
            quality: quality,
            progress: progress
        )
    }

    public func activate(profile: WallpaperProfile) async throws {
        let ids = Set(await library.allItems().map(\.id))
        try await runtimeStore.save(profile: profile, availableMediaIDs: ids)
    }

    public func activeConfiguration() async throws -> RuntimeConfiguration? {
        try await runtimeStore.load()
    }

    public func lockScreenCompatibility(
        storeURL: URL = LockScreenStoreInspector.defaultStoreURL(),
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> LockScreenCompatibilityReport {
        lockScreenInspector.inspect(
            storeURL: storeURL,
            operatingSystemVersion: operatingSystemVersion
        )
    }

    public func applyExperimentalLockScreen(mediaID: UUID) async throws -> LockScreenApplyResult {
        guard let item = await library.item(id: mediaID) else {
            throw MediaLibraryError.itemNotFound(mediaID)
        }
        switch item.kind {
        case .video:
            return try lockScreenService.apply(
                videoURL: await library.preparedURL(for: item),
                previewURL: await library.posterURL(for: item),
                title: item.title
            )
        case .image:
            return try lockScreenService.applyStaticImage(
                imageURL: await library.preparedURL(for: item)
            )
        }
    }

    public func restoreExperimentalLockScreen() throws {
        try lockScreenService.restore()
    }

    public func hasExperimentalLockScreenBackup() -> Bool {
        lockScreenService.hasRestorableBackup
    }

    public func applyAerialLockScreenCarrier(assetID: String) throws -> LockScreenApplyResult {
        try lockScreenService.applyAerialCarrier(assetID: assetID)
    }

    public func restoreAerialLockScreenCarrier() throws {
        try lockScreenService.restoreAerialCarrierIndex()
    }

    public func hasAerialLockScreenCarrierBackup() -> Bool {
        lockScreenService.hasAerialCarrierBackup
    }

    public func isAerialLockScreenCarrierSelected(assetID: String) throws -> Bool {
        try lockScreenService.isAerialCarrierSelected(assetID: assetID)
    }

    @discardableResult
    public func activateScreenSaverModule(at moduleURL: URL) throws -> Int {
        try lockScreenService.activateScreenSaverModule(at: moduleURL)
    }
}
