import AppKit
import AVFoundation
import CoreGraphics
import Darwin

private enum InstalledPaths {
    static let support = URL(
        fileURLWithPath: "/Library/Application Support/Wallpaper Studio/Login Wallpaper",
        isDirectory: true
    )
    static let video = support.appendingPathComponent("Background.mov")
    static let configuration = support.appendingPathComponent("Configuration.plist")
}

private struct LoginRendererConfiguration: Codable {
    let schemaVersion: Int
    let scaling: String
    let zoom: Double
    let horizontalPosition: Double
    let verticalPosition: Double
    let muteVideo: Bool
    let volume: Double
    let displayID: String?
}

@MainActor
private final class PlayerWindowController {
    let window: NSWindow
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let playerLayer: AVPlayerLayer
    private let configuration: LoginRendererConfiguration
    private var audioEnableTask: Task<Void, Never>?
    private var occlusionObserver: NSObjectProtocol?
    private var isPresented = false

    init(screen: NSScreen, configuration: LoginRendererConfiguration) {
        self.configuration = configuration
        let item = AVPlayerItem(url: InstalledPaths.video)
        player = AVQueuePlayer(items: [])
        looper = AVPlayerLooper(player: player, templateItem: item)
        // Audio is enabled only after the video layer is actually visible.
        player.isMuted = true
        player.volume = Float(min(1, max(0, configuration.volume)))
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // The system lock wallpaper is a normal-level window created after the
        // lock event. Screen-saver level keeps our video above that background;
        // Apple's secure authentication controls use a higher protected layer.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))

        let contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        playerLayer = AVPlayerLayer(player: player)
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = switch configuration.scaling {
        case "fit": .resizeAspect
        case "stretch": .resize
        default: .resizeAspectFill
        }
        contentView.layer?.addSublayer(playerLayer)
        layout(in: contentView.bounds)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateAudibility() }
        }
    }

    func layout(in bounds: CGRect) {
        let zoom = CGFloat(min(3, max(0.5, configuration.zoom)))
        let width = bounds.width * zoom
        let height = bounds.height * zoom
        let freeX = bounds.width - width
        let freeY = bounds.height - height
        let x = freeX / 2 + CGFloat(configuration.horizontalPosition) * freeX / 2
        let y = freeY / 2 + CGFloat(configuration.verticalPosition) * freeY / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = CGRect(x: x, y: y, width: width, height: height)
        CATransaction.commit()
    }

    func show() {
        isPresented = true
        audioEnableTask?.cancel()
        player.isMuted = true
        window.orderFrontRegardless()
        player.playImmediately(atRate: 1)
        audioEnableTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Wait for the macOS lock transition to finish before enabling audio.
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, isPresented else { return }
            for _ in 0..<40 where !playerLayer.isReadyForDisplay {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, isPresented else { return }
            }
            updateAudibility()
        }
    }

    func bringToFront() {
        guard isPresented else { return }
        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.updateAudibility() }
    }

    func hide() {
        isPresented = false
        audioEnableTask?.cancel()
        audioEnableTask = nil
        player.isMuted = true
        player.pause()
        window.orderOut(nil)
    }

    func pause() {
        audioEnableTask?.cancel()
        audioEnableTask = nil
        player.isMuted = true
        player.pause()
    }

    private func updateAudibility() {
        guard isPresented,
              window.isVisible,
              window.occlusionState.contains(.visible),
              playerLayer.isReadyForDisplay
        else {
            player.isMuted = true
            return
        }
        player.volume = Float(min(1, max(0, configuration.volume)))
        player.isMuted = configuration.muteVideo
    }
}

@MainActor
private final class LoginRendererDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var controllers: [PlayerWindowController] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var isLoginWindowSession = false
    private var isWallpaperActive = false
    private var presentationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        guard let configuration = loadConfiguration(),
              FileManager.default.fileExists(atPath: InstalledPaths.video.path)
        else {
            NSApp.terminate(nil)
            return
        }

        isLoginWindowSession = Self.isPreLoginSession
        controllers = selectedScreens(for: configuration).map {
            PlayerWindowController(screen: $0, configuration: configuration)
        }
        guard !controllers.isEmpty else {
            NSApp.terminate(nil)
            return
        }

        observeSessionChanges()
        if isLoginWindowSession || Self.isScreenLocked {
            showWallpaper()
        } else {
            hideWallpaper()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceObservers.forEach(NotificationCenter.default.removeObserver)
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        controllers.forEach { $0.hide() }
    }

    private func observeSessionChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.showWallpaper() } })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.hideWallpaperIfNeeded() } })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.pauseForSleep() } })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.resumeAfterWakeIfNeeded() } })

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.showWallpaper() } })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.hideWallpaperIfNeeded() } })
    }

    private func showWallpaper() {
        isWallpaperActive = true
        controllers.forEach { $0.show() }
        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // loginwindow creates its background shortly after the lock event.
            // Reassert ordering while that transition finishes.
            for delay in [150, 350, 700, 1_200] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, isWallpaperActive else { return }
                controllers.forEach { $0.bringToFront() }
            }
        }
    }

    private func hideWallpaperIfNeeded() {
        guard !isLoginWindowSession else { return }
        hideWallpaper()
    }

    private func hideWallpaper() {
        isWallpaperActive = false
        presentationTask?.cancel()
        presentationTask = nil
        controllers.forEach { $0.hide() }
    }

    private func pauseForSleep() {
        controllers.forEach { $0.pause() }
    }

    private func resumeAfterWakeIfNeeded() {
        if isWallpaperActive || isLoginWindowSession || Self.isScreenLocked {
            showWallpaper()
        }
    }

    private func loadConfiguration() -> LoginRendererConfiguration? {
        guard let data = try? Data(contentsOf: InstalledPaths.configuration) else { return nil }
        return try? PropertyListDecoder().decode(LoginRendererConfiguration.self, from: data)
    }

    private func selectedScreens(for configuration: LoginRendererConfiguration) -> [NSScreen] {
        guard let expectedID = configuration.displayID else { return NSScreen.screens }
        let matches = NSScreen.screens.filter { Self.displayID(for: $0) == expectedID }
        return matches.isEmpty ? NSScreen.screens : matches
    }

    private static var isPreLoginSession: Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return geteuid() == 0
        }
        let loginDone = (dictionary[kCGSessionLoginDoneKey as String] as? NSNumber)?.boolValue ?? false
        let userID = (dictionary[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value ?? UInt32.max
        return !loginDone || userID == 0 || geteuid() == 0
    }

    private static var isScreenLocked: Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dictionary["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
            || (dictionary["kCGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
    }

    private static func displayID(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

@main
private enum LoginWallpaperRendererApp {
    @MainActor
    static func main() {
        let delegate = LoginRendererDelegate()
        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
    }
}
