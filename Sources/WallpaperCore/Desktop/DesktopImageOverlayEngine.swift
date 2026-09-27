@preconcurrency import AppKit
import Foundation

/// Presents a still image at the desktop window level without changing the
/// system wallpaper selection. This lets the native wallpaper extension remain
/// selected underneath for Lock Screen while Desktop has independent content.
@MainActor
public final class DesktopImageOverlayEngine: NSObject {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private struct Session {
        let displayID: String
        let window: NSWindow
    }

    private var sessions: [Session] = []
    private var observers: [NSObjectProtocol] = []
    private var imageURL: URL?
    private var scaling: ContentScaling = .fill
    private var zoom = 1.0
    private var horizontalPosition = 0.0
    private var verticalPosition = 0.0
    private var displayTarget: DisplayTarget = .all
    private var screenLocked = false
    private var displayAsleep = false

    public override init() {
        super.init()
        installObservers()
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                DistributedNotificationCenter.default().removeObserver(observer)
            }
        }
    }

    public var activeDisplayIDs: Set<String> { Set(sessions.map(\.displayID)) }

    public func start(
        imageURL: URL,
        scaling: ContentScaling = .fill,
        zoom: Double = 1,
        horizontalPosition: Double = 0,
        verticalPosition: Double = 0,
        displayTarget: DisplayTarget = .all
    ) throws {
        guard NSImage(contentsOf: imageURL) != nil else {
            throw MediaProcessingError.unreadableMedia
        }
        self.imageURL = imageURL
        self.scaling = scaling
        self.zoom = min(3, max(0.5, zoom))
        self.horizontalPosition = min(1, max(-1, horizontalPosition))
        self.verticalPosition = min(1, max(-1, verticalPosition))
        self.displayTarget = displayTarget
        try rebuildSessions()
    }

    public func stop() {
        sessions.forEach { $0.window.orderOut(nil) }
        sessions.removeAll()
        imageURL = nil
        screenLocked = false
        displayAsleep = false
    }

    private func rebuildSessions() throws {
        guard let imageURL, let image = NSImage(contentsOf: imageURL) else { return }
        sessions.forEach { $0.window.orderOut(nil) }
        sessions.removeAll()

        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        for screen in try DisplayCatalog.screens(for: displayTarget) {
            guard let displayID = DisplayCatalog.persistentID(for: screen) else { continue }
            let window = OverlayWindow(
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

            let imageView = NSImageView(frame: CGRect(origin: .zero, size: screen.frame.size))
            imageView.image = image
            imageView.imageAlignment = .alignCenter
            imageView.imageFrameStyle = .none
            imageView.imageScaling = imageScaling
            imageView.wantsLayer = true
            imageView.layer?.masksToBounds = true
            var placement = CGAffineTransform(scaleX: zoom, y: zoom)
            placement.tx = horizontalPosition * screen.frame.width * 0.5
            placement.ty = verticalPosition * screen.frame.height * 0.5
            imageView.layer?.setAffineTransform(placement)
            window.contentView = imageView
            // The secure Lock Screen is above the Desktop window level. Keep
            // this fully opaque surface ready underneath it so macOS cannot
            // reveal the native wallpaper between unlock and renderer wake-up.
            window.orderFrontRegardless()
            sessions.append(Session(displayID: displayID, window: window))
        }
    }

    private var imageScaling: NSImageScaling {
        switch scaling {
        case .fill: .scaleProportionallyUpOrDown
        case .fit: .scaleProportionallyDown
        case .stretch: .scaleAxesIndependently
        }
    }

    private func updateVisibility() {
        guard !screenLocked && !displayAsleep else { return }
        for session in sessions {
            session.window.orderFrontRegardless()
        }
    }

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.rebuildSessions() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayAsleep = true
                self?.updateVisibility()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayAsleep = false
                self?.updateVisibility()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.screenLocked == false, self?.displayAsleep == false else { return }
                self?.sessions.forEach { $0.window.orderFrontRegardless() }
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = true }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenLocked = false
                self?.displayAsleep = false
                self?.updateVisibility()
            }
        })

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenLocked = true
                self?.updateVisibility()
            }
        })
        observers.append(distributed.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenLocked = false
                self?.updateVisibility()
            }
        })
    }
}
