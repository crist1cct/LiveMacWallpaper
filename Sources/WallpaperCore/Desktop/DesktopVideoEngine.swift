@preconcurrency import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

@MainActor
public final class DesktopVideoEngine: NSObject {
    private final class WallpaperWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private struct DisplaySession {
        let displayID: String
        let displayBounds: CGRect
        let window: NSWindow
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        let playerLayer: AVPlayerLayer
    }

    private var sessions: [DisplaySession] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var currentVideoURL: URL?
    private var currentScaling: ContentScaling = .fill
    private var currentZoom = 1.0
    private var currentHorizontalPosition = 0.0
    private var currentVerticalPosition = 0.0
    private var currentMuteVideo = true
    private var currentVolume = 0.5
    private var currentDisplayTarget: DisplayTarget = .all
    private var currentPauseInLowPowerMode = true
    private var userPaused = false
    private var systemPaused = false
    private var coveredDisplayIDs: Set<String> = []
    private var visibilityTimer: Timer?

    public override init() {
        super.init()
        installObservers()
    }

    deinit {
        MainActor.assumeIsolated {
            visibilityTimer?.invalidate()
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
                NSWorkspace.shared.notificationCenter.removeObserver(token)
                DistributedNotificationCenter.default().removeObserver(token)
            }
        }
    }

    public var isRunning: Bool { !sessions.isEmpty }
    public var isPaused: Bool {
        userPaused || systemPaused || (!sessions.isEmpty && coveredDisplayIDs == activeDisplayIDs)
    }
    public var activeDisplayIDs: Set<String> { Set(sessions.map(\.displayID)) }

    public func start(
        videoURL: URL,
        scaling: ContentScaling = .fill,
        zoom: Double = 1,
        horizontalPosition: Double = 0,
        verticalPosition: Double = 0,
        muteVideo: Bool = true,
        volume: Double = 0.5,
        displayTarget: DisplayTarget = .all,
        pauseInLowPowerMode: Bool = true
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        _ = try await asset.load(.duration)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw MediaProcessingError.missingVideoTrack
        }

        currentVideoURL = videoURL
        currentScaling = scaling
        currentZoom = min(3, max(0.5, zoom))
        currentHorizontalPosition = min(1, max(-1, horizontalPosition))
        currentVerticalPosition = min(1, max(-1, verticalPosition))
        currentMuteVideo = muteVideo
        currentVolume = min(1, max(0, volume))
        currentDisplayTarget = displayTarget
        currentPauseInLowPowerMode = pauseInLowPowerMode
        userPaused = false
        try rebuildSessions()
        guard await waitUntilReadyForDisplay() else {
            stop()
            throw MediaProcessingError.unreadableMedia
        }
    }

    public func stop() {
        sessions.forEach {
            $0.player.pause()
            $0.looper.disableLooping()
            $0.window.orderOut(nil)
        }
        sessions.removeAll()
        currentVideoURL = nil
        currentDisplayTarget = .all
        userPaused = false
        systemPaused = false
        coveredDisplayIDs.removeAll()
    }

    public func pause() {
        userPaused = true
        updatePlaybackState()
    }

    public func resume() {
        userPaused = false
        updatePlaybackState()
    }

    private func rebuildSessions() throws {
        guard let currentVideoURL else { return }
        sessions.forEach {
            $0.player.pause()
            $0.looper.disableLooping()
            $0.window.orderOut(nil)
        }
        sessions.removeAll()

        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        for screen in try DisplayCatalog.screens(for: currentDisplayTarget) {
            guard let displayID = DisplayCatalog.persistentID(for: screen),
                  let directDisplayID = DisplayCatalog.directDisplayID(for: screen)
            else { continue }
            let window = WallpaperWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = level
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.canHide = false

            let item = AVPlayerItem(url: currentVideoURL)
            item.preferredForwardBufferDuration = 5
            item.preferredMaximumResolution = CGSize(
                width: CGFloat(CGDisplayPixelsWide(directDisplayID)),
                height: CGFloat(CGDisplayPixelsHigh(directDisplayID))
            )
            let player = AVQueuePlayer()
            player.isMuted = currentMuteVideo
            player.volume = Float(currentVolume)
            player.actionAtItemEnd = .none
            player.automaticallyWaitsToMinimizeStalling = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            let looper = AVPlayerLooper(player: player, templateItem: item)

            let layer = AVPlayerLayer(player: player)
            layer.frame = CGRect(origin: .zero, size: screen.frame.size)
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.videoGravity = videoGravity(for: currentScaling)
            layer.backgroundColor = NSColor.black.cgColor
            layer.drawsAsynchronously = true
            var placement = CGAffineTransform(
                scaleX: CGFloat(currentZoom),
                y: CGFloat(currentZoom)
            )
            placement.tx = CGFloat(currentHorizontalPosition) * screen.frame.width * 0.5
            placement.ty = CGFloat(currentVerticalPosition) * screen.frame.height * 0.5
            layer.setAffineTransform(placement)

            let contentView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.black.cgColor
            contentView.layer?.masksToBounds = true
            contentView.layer?.addSublayer(layer)
            window.contentView = contentView
            window.orderFrontRegardless()

            sessions.append(DisplaySession(
                displayID: displayID,
                displayBounds: CGDisplayBounds(directDisplayID),
                window: window,
                player: player,
                looper: looper,
                playerLayer: layer
            ))
        }
        evaluateDesktopVisibility()
        updatePlaybackState()
    }

    private func waitUntilReadyForDisplay() async -> Bool {
        guard !sessions.isEmpty else { return false }
        for _ in 0..<60 {
            if sessions.allSatisfy({ $0.playerLayer.isReadyForDisplay }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return false }
        }
        return sessions.allSatisfy { $0.playerLayer.isReadyForDisplay }
    }

    private func updatePlaybackState() {
        let lowPowerPaused = currentPauseInLowPowerMode
            && ProcessInfo.processInfo.isLowPowerModeEnabled
        for session in sessions {
            let shouldPause = userPaused
                || systemPaused
                || lowPowerPaused
                || coveredDisplayIDs.contains(session.displayID)
            if shouldPause {
                session.player.isMuted = true
                session.player.pause()
            } else {
                session.player.volume = Float(currentVolume)
                session.player.isMuted = currentMuteVideo
                session.player.playImmediately(atRate: 1)
            }
        }
    }

    /// Core Graphics exposes enough metadata to determine whether a normal app
    /// window intersects each display without requesting Screen Recording.
    /// Desktop elements and our own process are excluded from the query.
    private func evaluateDesktopVisibility() {
        guard !sessions.isEmpty, !systemPaused else { return }
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let ownPID = getpid()
        let ignoredOwners: Set<String> = [
            "Dock", "WindowServer", "WallpaperAgent", "ScreenSaverEngine",
            "WallpaperRenderer", "LoginWallpaperRenderer", "loginwindow"
        ]
        let appWindows = rawWindows.compactMap { info -> CGRect? in
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            guard layer == 0,
                  alpha > 0.01,
                  ownerPID != ownPID,
                  !ignoredOwners.contains(ownerName),
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 80,
                  bounds.height >= 80,
                  bounds.width * bounds.height >= 10_000
            else { return nil }
            return bounds
        }

        let updated = Set(sessions.compactMap { session in
            appWindows.contains { $0.intersects(session.displayBounds) }
                ? session.displayID
                : nil
        })
        guard updated != coveredDisplayIDs else { return }
        coveredDisplayIDs = updated
        updatePlaybackState()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.rebuildSessions() }
        })
        notificationTokens.append(center.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePlaybackState() }
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemPaused = true
                self?.updatePlaybackState()
            }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemPaused = false
                self?.sessions.forEach { $0.window.orderFrontRegardless() }
                self?.evaluateDesktopVisibility()
                self?.updatePlaybackState()
            }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessions.forEach { $0.window.orderFrontRegardless() }
                self?.evaluateDesktopVisibility()
            }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateDesktopVisibility() }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Keep the opaque Desktop surface ordered underneath the secure
                // session. Only playback is stopped, so there is no native
                // wallpaper flash when this user session becomes active again.
                self?.systemPaused = true
                self?.updatePlaybackState()
            }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessions.forEach { $0.window.orderFrontRegardless() }
                self?.systemPaused = false
                self?.evaluateDesktopVisibility()
                self?.updatePlaybackState()
            }
        })

        let distributed = DistributedNotificationCenter.default()
        notificationTokens.append(distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemPaused = true
                self?.updatePlaybackState()
            }
        })
        notificationTokens.append(distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemPaused = false
                self?.sessions.forEach { $0.window.orderFrontRegardless() }
                self?.evaluateDesktopVisibility()
                self?.updatePlaybackState()
            }
        })

        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateDesktopVisibility() }
        }
        if let visibilityTimer {
            RunLoop.main.add(visibilityTimer, forMode: .common)
        }
    }

    private func videoGravity(for scaling: ContentScaling) -> AVLayerVideoGravity {
        switch scaling {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }
}
