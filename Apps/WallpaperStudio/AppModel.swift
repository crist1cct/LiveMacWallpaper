import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore

enum AppSection: String, CaseIterable, Identifiable {
    case library
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Bibliotecă"
        case .settings: "Setări"
        }
    }

    var symbol: String {
        switch self {
        case .library: "photo.on.rectangle.angled"
        case .settings: "gearshape"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case videos
    case images
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Toate"
        case .videos: "Video"
        case .images: "Imagini"
        case .favorites: "Favorite"
        }
    }

}

struct MediaAssetURLs: Sendable {
    let prepared: URL
    let thumbnail: URL
    let poster: URL
}

struct ImportJob: Identifiable {
    let id: UUID
    let title: String
    var status: String
    var isFailed: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection? = .library
    @Published var libraryFilter: LibraryFilter = .all
    @Published var searchText = ""
    @Published var mediaItems: [MediaItem] = []
    @Published var mediaURLs: [UUID: MediaAssetURLs] = [:]
    @Published var selectedMediaID: UUID?
    @Published var selectedConfigurationDestination: WallpaperDestination = .desktop
    @Published var draftProfile = WallpaperProfile(name: "Profilul meu")
    @Published var activeProfile: WallpaperProfile?
    @Published var displays: [DisplayDescriptor] = DisplayCatalog.connectedDisplays
    @Published var importJobs: [ImportJob] = []
    @Published var isYouTubeSheetPresented = false
    @Published var youtubeHelperStatus: YouTubeHelperStatus = .unavailable
    @Published var isApplying = false
    @Published var applyingDestination: WallpaperDestination?
    @Published var isLoading = true
    @Published var bannerMessage: String?
    @Published var successMessage: String?
    @Published var isLoginItemEnabled = false
    @Published var isScreenSaverInstalled = false
    @Published var loginWallpaperStatus = LoginWallpaperStatus.notInstalled
    @Published var isLoginWallpaperOperationRunning = false
    @Published var loginWallpaperOperationLabel: String?
    @Published var appliedDisplayIDs: [WallpaperDestination: Set<String>] = [:]
    @Published var importQuality = MediaQuality(
        rawValue: UserDefaults.standard.string(forKey: "importQuality") ?? ""
    ) ?? .native {
        didSet { UserDefaults.standard.set(importQuality.rawValue, forKey: "importQuality") }
    }

    let desktopEngine = DesktopVideoEngine()
    let desktopImageOverlayEngine = DesktopImageOverlayEngine()
    let integrations = SystemIntegrationService()

    private let loginWallpaperService = LoginWallpaperService()
    private let wallpaperExtensionService = WallpaperExtensionService()
    private let backend: WallpaperBackend?
    private var hasStarted = false

    init() {
        do {
            backend = try WallpaperBackend.live()
        } catch {
            backend = nil
            bannerMessage = error.localizedDescription
        }
    }

    var filteredMediaItems: [MediaItem] {
        mediaItems.filter { item in
            let matchesFilter: Bool
            switch libraryFilter {
            case .all: matchesFilter = true
            case .videos: matchesFilter = item.kind == .video
            case .images: matchesFilter = item.kind == .image
            case .favorites: matchesFilter = item.isFavorite
            }
            let matchesSearch = searchText.isEmpty
                || item.title.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesSearch
        }
    }

    var selectedMediaItem: MediaItem? {
        guard let selectedMediaID else { return nil }
        return mediaItems.first { $0.id == selectedMediaID }
    }

    var backendLocationLabel: String {
        backend?.directories.root.path(percentEncoded: false) ?? "Indisponibilă"
    }

    var loginWallpaperNeedsUpdate: Bool {
        guard loginWallpaperStatus.isInstalled else { return false }
        return !loginWallpaperStatus.isReady
            || UserDefaults.standard.string(forKey: "loginWallpaperConfigurationSignature")
            != loginWallpaperConfigurationSignature
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refresh()
        isLoading = false
        if Bundle.main.bundleURL.path.hasPrefix("/Volumes/"), bannerMessage == nil {
            bannerMessage = "Mută Wallpaper Studio în Applications pentru ca fundalul video să pornească automat și după autentificare."
        }
    }

    func refresh() async {
        guard let backend else { return }
        do {
            refreshDisplays()
            // Register the native macOS 26 wallpaper provider as soon as the
            // app is installed. Without this first-launch step, System Settings
            // can show the provider but fail with “This wallpaper can't be
            // opened” until the user has already applied Lock Screen once.
            _ = wallpaperExtensionService.ensureRegistered()
            let items = await backend.mediaItems()
            var urls: [UUID: MediaAssetURLs] = [:]
            for item in items {
                let resolved = await backend.mediaURLs(for: item)
                urls[item.id] = MediaAssetURLs(
                    prepared: resolved.prepared,
                    thumbnail: resolved.thumbnail,
                    poster: resolved.poster
                )
            }
            mediaItems = items
            mediaURLs = urls
            if let configuration = try await backend.activeConfiguration() {
                activeProfile = configuration.activeProfile
                draftProfile = configuration.activeProfile
            }
            youtubeHelperStatus = await backend.youtubeHelperStatus()
            isLoginItemEnabled = integrations.loginItemStatus == .enabled
            isScreenSaverInstalled = integrations.isScreenSaverInstalled
            loginWallpaperStatus = LoginWallpaperStatus(
                isInstalled: wallpaperExtensionService.isSelected,
                isReady: wallpaperExtensionService.isAvailable && wallpaperExtensionService.isSelected,
                installedAt: nil
            )
        } catch {
            show(error)
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Importă în Bibliotecă"
        panel.prompt = "Importă"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .video]
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL]) {
        guard let backend else { return }
        for url in urls {
            let jobID = UUID()
            importJobs.append(ImportJob(
                id: jobID,
                title: url.deletingPathExtension().lastPathComponent,
                status: "Se pregătește",
                isFailed: false
            ))

            Task {
                do {
                    _ = try await backend.importLocalFile(url, quality: importQuality) { [weak self] phase in
                        Task { @MainActor in
                            self?.updateJob(jobID, status: Self.label(for: phase))
                        }
                    }
                    removeJob(jobID)
                    await refreshLibraryOnly()
                } catch {
                    updateJob(jobID, status: error.localizedDescription, failed: true)
                }
            }
        }
    }

    func inspectYouTube(_ url: String) async throws -> YouTubeMetadata {
        guard let backend else { throw AppModelError.backendUnavailable }
        return try await backend.inspectYouTubeURL(url)
    }

    func importYouTube(
        _ url: String,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        guard let backend else { throw AppModelError.backendUnavailable }
        _ = try await backend.importYouTubeVideo(
            url,
            rightsConfirmation: .confirmedNow(),
            quality: .original
        ) { phase in
            Task { @MainActor in progress(Self.label(for: phase)) }
        }
        await refreshLibraryOnly()
    }

    func toggleFavorite(_ item: MediaItem) {
        guard let backend else { return }
        Task {
            do {
                try await backend.setFavorite(id: item.id, isFavorite: !item.isFavorite)
                await refreshLibraryOnly()
            } catch {
                show(error)
            }
        }
    }

    func rename(_ item: MediaItem, to title: String) {
        guard let backend else { return }
        Task {
            do {
                try await backend.renameMedia(id: item.id, title: title)
                await refreshLibraryOnly()
            } catch {
                show(error)
            }
        }
    }

    func delete(_ item: MediaItem) {
        guard let backend else { return }
        if Self.profile(draftProfile, directlyUses: item.id)
            || activeProfile.map({ Self.profile($0, directlyUses: item.id) }) == true
        {
            show(AppModelError.mediaInUse)
            return
        }
        Task {
            do {
                try await backend.removeMedia(id: item.id)
                if selectedMediaID == item.id { selectedMediaID = nil }
                await refreshLibraryOnly()
            } catch {
                show(error)
            }
        }
    }

    func applyProfile() async {
        _ = await runApply(
            profile: draftProfile,
            destinations: Set(WallpaperDestination.allCases),
            applyingDestination: nil,
            successLabel: "Configurația a fost aplicată."
        )
    }

    func applyProfileAndInstallLockScreen() async {
        let requested = draftProfile
        await applyProfile()
        guard activeProfile == requested else { return }
        await updateInstalledLockPoster()
    }

    func applyDestination(_ destination: WallpaperDestination) async {
        let previousDraft = draftProfile
        var profile = activeProfile ?? draftProfile
        profile[destination] = draftProfile[destination]
        var destinations: Set<WallpaperDestination> = [destination]
        if destination == .desktop,
           profile.screenSaver.selection == .follow(.desktop)
        {
            destinations.insert(.screenSaver)
        }
        if destinations.contains(.screenSaver),
           profile.lockScreen.selection == .follow(.screenSaver)
        {
            destinations.insert(.lockScreen)
        }
        if destination == .lockScreen,
           profile.lockScreen.selection == .follow(.screenSaver)
        {
            profile.screenSaver = draftProfile.screenSaver
            destinations.insert(.screenSaver)
        }
        let succeeded = await runApply(
            profile: profile,
            destinations: destinations,
            applyingDestination: destination,
            successLabel: "\(Self.destinationLabel(destination)) a fost aplicat."
        )
        guard succeeded else { return }
        var retainedDraft = previousDraft
        retainedDraft[destination] = profile[destination]
        draftProfile = retainedDraft
    }

    func applyLockScreenAndInstallRenderer() async {
        let requested = draftProfile.lockScreen
        await applyDestination(.lockScreen)
        guard activeProfile?.lockScreen == requested else { return }
        await updateInstalledLockPoster()
    }

    func apply(_ item: MediaItem, for destination: WallpaperDestination) async {
        draftProfile[destination].selection = .media(item.id)
        resetPlacement(for: destination)
        selectedMediaID = item.id
        await applyDestination(destination)
    }

    func applyForScreenSaverAndAuthentication(_ item: MediaItem) async {
        let previousDraft = draftProfile
        var profile = activeProfile ?? draftProfile
        profile.screenSaver.selection = .media(item.id)
        profile.lockScreen.selection = .follow(.screenSaver)
        let succeeded = await runApply(
            profile: profile,
            destinations: [.screenSaver, .lockScreen],
            applyingDestination: .lockScreen,
            successLabel: "Screen Saver și fundalul de autentificare au fost configurate."
        )
        guard succeeded else { return }
        var retainedDraft = previousDraft
        retainedDraft.screenSaver = profile.screenSaver
        retainedDraft.lockScreen = profile.lockScreen
        draftProfile = retainedDraft
        await updateInstalledLockPoster()
    }

    func lockNowWithWallpaperStudio() async {
        let requestedConfiguration = draftProfile.lockScreen
        await applyDestination(.lockScreen)
        guard let profile = activeProfile,
              profile.lockScreen == requestedConfiguration
        else {
            return
        }

        do {
            try await installNativeLockScreen(for: profile)
            try integrations.requestNativeLockScreen()
            successMessage = "Mac-ul a fost blocat cu videoclipul selectat pe ecranul securizat."
        } catch {
            show(error)
        }
    }

    func testConfiguredScreenSaver() async {
        let requested = draftProfile.screenSaver
        await applyDestination(.screenSaver)
        guard activeProfile?.screenSaver == requested else { return }
        do {
            let application = try await integrations.startScreenSaver()
            successMessage = "Screen Saver-ul Wallpaper Studio a pornit cu videoclipul selectat."
            Task { [weak self] in
                guard let self else { return }
                await self.integrations.waitForTermination(of: application)
            }
        } catch {
            show(error)
        }
    }

    func restoreLockScreen() {
        guard let backend else { return }
        Task {
            do {
                try await backend.restoreExperimentalLockScreen()
                successMessage = "Setările Lock Screen au fost restaurate."
            } catch {
                show(error)
            }
        }
    }

    private func updateInstalledLockPoster() async {
        do {
            guard let profile = activeProfile else { return }
            try await installNativeLockScreen(for: profile)
            UserDefaults.standard.set(
                loginWallpaperConfigurationSignature,
                forKey: "loginWallpaperConfigurationSignature"
            )
            successMessage = "Videoclipul a fost instalat în motorul nativ Wallpaper din macOS 26."
        } catch {
            show(error)
        }
    }

    private func installNativeLockScreen(for profile: WallpaperProfile) async throws {
        let selection = try ProfileValidator().resolvedSelection(
            for: .lockScreen,
            in: profile,
            availableMediaIDs: Set(mediaItems.map(\.id))
        )
        guard case let .media(id) = selection,
              let item = mediaItems.first(where: { $0.id == id }),
              item.kind == .video,
              let urls = mediaURLs[id]
        else { throw AppModelError.lockScreenMediaRequired }

        if loginWallpaperService.hasLegacyIntegration {
            try await loginWallpaperService.uninstall()
        }
        if let backend, await backend.hasAerialLockScreenCarrierBackup() {
            try await backend.restoreAerialLockScreenCarrier()
        }

        try wallpaperExtensionService.apply(
            item: item,
            mediaURL: urls.prepared,
            posterURL: urls.poster,
            desktopImageURL: desktopImageURL(for: profile),
            configuration: profile.lockScreen
        )
        loginWallpaperStatus = LoginWallpaperStatus(
            isInstalled: true,
            isReady: true,
            installedAt: Date()
        )
    }

    private func desktopImageURL(for profile: WallpaperProfile) -> URL? {
        guard let selection = try? ProfileValidator().resolvedSelection(
            for: .desktop,
            in: profile,
            availableMediaIDs: Set(mediaItems.map(\.id))
        ), case let .media(id) = selection,
           let item = mediaItems.first(where: { $0.id == id }),
           let urls = mediaURLs[id]
        else { return nil }
        return item.kind == .image ? urls.prepared : urls.poster
    }

    func uninstallLoginWallpaper() async {
        guard !isLoginWallpaperOperationRunning else { return }
        isLoginWallpaperOperationRunning = true
        bannerMessage = nil
        successMessage = nil
        loginWallpaperOperationLabel = "Se restaurează fundalul Apple…"
        defer {
            isLoginWallpaperOperationRunning = false
            loginWallpaperOperationLabel = nil
            loginWallpaperStatus = loginWallpaperService.status
        }

        do {
            try wallpaperExtensionService.restoreAppleWallpaper()
            if loginWallpaperService.hasLegacyIntegration {
                try await loginWallpaperService.uninstall()
            }
            if let backend, await backend.hasAerialLockScreenCarrierBackup() {
                try await backend.restoreAerialLockScreenCarrier()
            }
            UserDefaults.standard.removeObject(forKey: "loginWallpaperConfigurationSignature")
            successMessage = "Extensia a fost dezactivată, iar configurația Wallpaper Apple a fost restaurată."
        } catch {
            show(error)
        }
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            try integrations.setLoginItemEnabled(enabled)
            isLoginItemEnabled = integrations.loginItemStatus == .enabled
        } catch {
            isLoginItemEnabled = integrations.loginItemStatus == .enabled
            show(error)
        }
    }

    func installScreenSaver() {
        do {
            try integrations.installScreenSaver()
            isScreenSaverInstalled = true
            successMessage = "Screen Saver-ul Wallpaper Studio a fost actualizat."
        } catch {
            show(error)
        }
    }

    func revealLibraryInFinder() {
        guard let backend else { return }
        integrations.revealApplicationSupport(backend.directories)
    }

    func configure(_ item: MediaItem, for destination: WallpaperDestination) {
        draftProfile[destination].selection = .media(item.id)
        resetPlacement(for: destination)
        selectedMediaID = item.id
        selectedConfigurationDestination = destination
        bannerMessage = nil
        successMessage = nil
    }

    func applyFromLibrary(_ destination: WallpaperDestination) async {
        resetPlacement(for: destination)
        if destination == .lockScreen {
            await applyLockScreenAndInstallRenderer()
        } else {
            await applyDestination(destination)
        }
    }

    private func resetPlacement(for destination: WallpaperDestination) {
        draftProfile[destination].scaling = .fill
        draftProfile[destination].zoom = 1
        draftProfile[destination].horizontalPosition = 0
        draftProfile[destination].verticalPosition = 0
    }

    func refreshDisplays() {
        displays = DisplayCatalog.connectedDisplays
        normalizeDisconnectedDisplayTargets()
    }

    func dismissImportJob(_ id: UUID) {
        removeJob(id)
    }

    func toggleDesktopPlayback() {
        desktopEngine.isPaused ? desktopEngine.resume() : desktopEngine.pause()
    }

    func dismissMessages() {
        bannerMessage = nil
        successMessage = nil
    }

    @discardableResult
    private func runApply(
        profile: WallpaperProfile,
        destinations: Set<WallpaperDestination>,
        applyingDestination: WallpaperDestination?,
        successLabel: String
    ) async -> Bool {
        guard let backend, !isApplying else { return false }
        isApplying = true
        self.applyingDestination = applyingDestination
        bannerMessage = nil
        successMessage = nil
        defer {
            isApplying = false
            self.applyingDestination = nil
        }

        do {
            let ids = Set(mediaItems.map(\.id))
            let validator = ProfileValidator()
            let desktopSelection = try validator.resolvedSelection(
                for: .desktop,
                in: profile,
                availableMediaIDs: ids
            )
            let screenSaverSelection = try validator.resolvedSelection(
                for: .screenSaver,
                in: profile,
                availableMediaIDs: ids
            )
            let lockSelection = try validator.resolvedSelection(
                for: .lockScreen,
                in: profile,
                availableMediaIDs: ids
            )

            var verifiedDisplayIDs: [WallpaperDestination: Set<String>] = [:]

            if destinations.contains(.screenSaver) {
                verifiedDisplayIDs[.screenSaver] = try await applyScreenSaver(
                    selection: screenSaverSelection,
                    configuration: profile.screenSaver
                )
            }

            if destinations.contains(.desktop) {
                verifiedDisplayIDs[.desktop] = try await applyDesktop(
                    desktopSelection,
                    configuration: profile.desktop
                )
            }

            if destinations.contains(.lockScreen) {
                if case .media = lockSelection {
                    verifiedDisplayIDs[.lockScreen] = try DisplayCatalog.resolvedDisplayIDs(
                        for: profile.lockScreen.displayTarget
                    )
                } else {
                    verifiedDisplayIDs[.lockScreen] = []
                }
                switch profile.lockScreen.selection {
                case .follow(.screenSaver):
                    if await backend.hasExperimentalLockScreenBackup() {
                        try await backend.restoreExperimentalLockScreen()
                    }
                case .media:
                    guard case .media = lockSelection else {
                        throw AppModelError.invalidDestinationSelection
                    }
                    if await backend.hasExperimentalLockScreenBackup() {
                        try await backend.restoreExperimentalLockScreen()
                    }
                case .systemDefault, .off:
                    if await backend.hasExperimentalLockScreenBackup() {
                        try await backend.restoreExperimentalLockScreen()
                    }
                case .follow:
                    throw AppModelError.invalidDestinationSelection
                }
            }

            try await backend.activate(profile: profile)
            activeProfile = profile

            var rendererReady = true
            if destinations.contains(.desktop) {
                if case .media = desktopSelection {
                    rendererReady = await integrations.startRendererAndWaitUntilReady(
                        profileID: profile.id,
                        expectedDisplayIDs: verifiedDisplayIDs[.desktop] ?? []
                    )
                    if rendererReady {
                        desktopEngine.stop()
                        desktopImageOverlayEngine.stop()
                    }
                } else {
                    integrations.notifyRenderer()
                }
            }

            appliedDisplayIDs.merge(verifiedDisplayIDs) { _, new in new }

            if !rendererReady {
                successMessage = "\(successLabel) Păstrează aplicația deschisă pentru redarea video pe Desktop."
            } else {
                successMessage = successLabel
            }
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func applyScreenSaver(
        selection: DestinationSelection,
        configuration: DestinationConfiguration
    ) async throws -> Set<String> {
        switch selection {
        case let .media(id):
            guard let item = mediaItems.first(where: { $0.id == id }),
                  let urls = mediaURLs[id],
                  let backend
            else {
                throw MediaLibraryError.itemNotFound(id)
            }
            if !integrations.isScreenSaverInstalled || !integrations.isScreenSaverCurrent {
                try integrations.installScreenSaver()
                isScreenSaverInstalled = true
            }
            try await integrations.configureScreenSaver(
                item: item,
                mediaURL: urls.prepared,
                configuration: configuration,
                cacheDirectory: backend.directories.runtime
            )
            return try DisplayCatalog.resolvedDisplayIDs(for: configuration.displayTarget)
        case .systemDefault, .off:
            try integrations.clearScreenSaverConfiguration()
            if let backend, await backend.hasAerialLockScreenCarrierBackup() {
                try await backend.restoreAerialLockScreenCarrier()
            }
            return []
        case .follow:
            throw AppModelError.invalidDestinationSelection
        }
    }

    private func refreshLibraryOnly() async {
        guard let backend else { return }
        let items = await backend.mediaItems()
        var urls: [UUID: MediaAssetURLs] = [:]
        for item in items {
            let resolved = await backend.mediaURLs(for: item)
            urls[item.id] = MediaAssetURLs(
                prepared: resolved.prepared,
                thumbnail: resolved.thumbnail,
                poster: resolved.poster
            )
        }
        mediaItems = items
        mediaURLs = urls
    }

    private func restoreRegularScreenSaverRuntime() async {
        guard let profile = activeProfile else { return }
        do {
            let selection = try ProfileValidator().resolvedSelection(
                for: .screenSaver,
                in: profile,
                availableMediaIDs: Set(mediaItems.map(\.id))
            )
            _ = try await applyScreenSaver(
                selection: selection,
                configuration: profile.screenSaver
            )
        } catch {
            show(error)
        }
    }

    private func applyDesktop(
        _ selection: DestinationSelection,
        configuration: DestinationConfiguration
    ) async throws -> Set<String> {
        switch selection {
        case let .media(id):
            guard let item = mediaItems.first(where: { $0.id == id }),
                  let urls = mediaURLs[id]
            else {
                throw MediaLibraryError.itemNotFound(id)
            }
            if item.kind == .video {
                desktopImageOverlayEngine.stop()
                try await desktopEngine.start(
                    videoURL: urls.prepared,
                    scaling: configuration.scaling,
                    zoom: configuration.zoom,
                    horizontalPosition: configuration.horizontalPosition,
                    verticalPosition: configuration.verticalPosition,
                    muteVideo: configuration.muteVideo,
                    volume: configuration.volume,
                    displayTarget: configuration.displayTarget,
                    pauseInLowPowerMode: configuration.pauseInLowPowerMode
                )
                return desktopEngine.activeDisplayIDs
            } else {
                desktopEngine.stop()
                try desktopImageOverlayEngine.start(
                    imageURL: urls.prepared,
                    scaling: configuration.scaling,
                    zoom: configuration.zoom,
                    horizontalPosition: configuration.horizontalPosition,
                    verticalPosition: configuration.verticalPosition,
                    displayTarget: configuration.displayTarget
                )
                return desktopImageOverlayEngine.activeDisplayIDs
            }
        case .systemDefault, .off:
            desktopEngine.stop()
            desktopImageOverlayEngine.stop()
            return []
        case .follow:
            return []
        }
    }

    private func normalizeDisconnectedDisplayTargets() {
        let availableIDs = Set(displays.map(\.id))
        let fallbackID = displays.first(where: \.isMain)?.id ?? displays.first?.id
        guard let fallbackID else { return }
        for destination in WallpaperDestination.allCases {
            guard case let .display(id) = draftProfile[destination].displayTarget,
                  !availableIDs.contains(id)
            else {
                continue
            }
            draftProfile[destination].displayTarget = .display(fallbackID)
        }
    }

    private func updateJob(_ id: UUID, status: String, failed: Bool = false) {
        guard let index = importJobs.firstIndex(where: { $0.id == id }) else { return }
        importJobs[index].status = status
        importJobs[index].isFailed = failed
    }

    private func removeJob(_ id: UUID) {
        importJobs.removeAll { $0.id == id }
    }

    private func show(_ error: Error) {
        bannerMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func label(for phase: ImportPhase) -> String {
        switch phase {
        case .validating: "Se verifică fișierul"
        case .copying: "Se copiază"
        case .inspecting: "Se citește informația media"
        case let .preparing(progress):
            progress.map { "Se optimizează · \(Int($0 * 100))%" } ?? "Se optimizează"
        case .generatingPreview: "Se creează previzualizarea"
        case .saving: "Se salvează"
        }
    }

    private static func label(for phase: YouTubeImportPhase) -> String {
        switch phase {
        case .validatingURL: "Se verifică linkul"
        case .readingMetadata: "Se citește informația video"
        case let .downloading(progress):
            progress.map { "Se descarcă · \(Int($0 * 100))%" } ?? "Se descarcă"
        case let .preparingMedia(phase): label(for: phase)
        case .completed: "Adăugat în Bibliotecă"
        }
    }

    private static func profile(_ profile: WallpaperProfile, directlyUses id: UUID) -> Bool {
        WallpaperDestination.allCases.contains { destination in
            if case let .media(selectedID) = profile[destination].selection {
                return selectedID == id
            }
            return false
        }
    }

    private var loginWallpaperConfigurationSignature: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(draftProfile.lockScreen) else { return "" }
        return "native-wallpaper-extension-v1:" + data.base64EncodedString()
    }

    private static func destinationLabel(_ destination: WallpaperDestination) -> String {
        switch destination {
        case .desktop: "Desktop"
        case .screenSaver: "Screen Saver"
        case .lockScreen: "Lock Screen"
        }
    }
}

enum AppModelError: Error, LocalizedError {
    case backendUnavailable
    case experimentalLockScreenDisabled
    case invalidDestinationSelection
    case mediaInUse
    case lockScreenMediaRequired
    case loginWallpaperUpdateRequired

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            "Biblioteca nu poate fi deschisă."
        case .experimentalLockScreenDisabled:
            "Activează mai întâi funcția experimentală Lock Screen în Setări."
        case .invalidDestinationSelection:
            "Această combinație de destinații nu poate fi aplicată."
        case .mediaInUse:
            "Acest element este folosit de configurația curentă. Alege alt conținut înainte să-l ștergi."
        case .lockScreenMediaRequired:
            "Alege un video sau o imagine pentru Lock Screen înainte de blocare."
        case .loginWallpaperUpdateRequired:
            "Alege un videoclip din Bibliotecă și deschide Configurare pentru Lock Screen înainte de blocare."
        }
    }
}
