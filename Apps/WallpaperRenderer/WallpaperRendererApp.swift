import AppKit
import SwiftUI
import WallpaperCore

@main
struct WallpaperRendererApp: App {
    @NSApplicationDelegateAdaptor(RendererDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class RendererDelegate: NSObject, NSApplicationDelegate {
    private static let readyNotification = Notification.Name(
        "com.livemacwallpaper.rendererReady"
    )
    private let engine = DesktopVideoEngine()
    private let imageOverlayEngine = DesktopImageOverlayEngine()
    private var backend: WallpaperBackend?
    private var configurationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        do {
            backend = try WallpaperBackend.live()
        } catch {
            NSApplication.shared.terminate(nil)
            return
        }

        configurationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.livemacwallpaper.configurationChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        Task { await reload() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let configurationObserver {
            DistributedNotificationCenter.default().removeObserver(configurationObserver)
        }
        engine.stop()
        imageOverlayEngine.stop()
    }

    private func reload() async {
        guard let backend else { return }
        do {
            guard let runtime = try await backend.activeConfiguration() else {
                engine.stop()
                imageOverlayEngine.stop()
                return
            }
            let items = await backend.mediaItems()
            let selection = try ProfileValidator().resolvedSelection(
                for: .desktop,
                in: runtime.activeProfile,
                availableMediaIDs: Set(items.map(\.id))
            )

            switch selection {
            case let .media(id):
                guard let item = items.first(where: { $0.id == id }) else { return }
                let urls = await backend.mediaURLs(for: item)
                if item.kind == .video {
                    imageOverlayEngine.stop()
                    try await engine.start(
                        videoURL: urls.prepared,
                        scaling: runtime.activeProfile.desktop.scaling,
                        zoom: runtime.activeProfile.desktop.zoom,
                        horizontalPosition: runtime.activeProfile.desktop.horizontalPosition,
                        verticalPosition: runtime.activeProfile.desktop.verticalPosition,
                        muteVideo: runtime.activeProfile.desktop.muteVideo,
                        volume: runtime.activeProfile.desktop.volume,
                        displayTarget: runtime.activeProfile.desktop.displayTarget,
                        pauseInLowPowerMode: runtime.activeProfile.desktop.pauseInLowPowerMode
                    )
                    notifyReady(
                        profileID: runtime.activeProfile.id,
                        displayIDs: engine.activeDisplayIDs
                    )
                } else {
                    engine.stop()
                    try imageOverlayEngine.start(
                        imageURL: urls.prepared,
                        scaling: runtime.activeProfile.desktop.scaling,
                        zoom: runtime.activeProfile.desktop.zoom,
                        horizontalPosition: runtime.activeProfile.desktop.horizontalPosition,
                        verticalPosition: runtime.activeProfile.desktop.verticalPosition,
                        displayTarget: runtime.activeProfile.desktop.displayTarget
                    )
                    notifyReady(profileID: runtime.activeProfile.id, displayIDs: imageOverlayEngine.activeDisplayIDs)
                }
            case .systemDefault, .off:
                engine.stop()
                imageOverlayEngine.stop()
                notifyReady(profileID: runtime.activeProfile.id, displayIDs: [])
            case .follow:
                break
            }
        } catch {
            engine.stop()
            imageOverlayEngine.stop()
        }
    }

    private func notifyReady(profileID: UUID, displayIDs: Set<String>) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.readyNotification,
            object: nil,
            userInfo: [
                "profileID": profileID.uuidString,
                "displayIDs": displayIDs.sorted()
            ],
            deliverImmediately: true
        )
    }
}
