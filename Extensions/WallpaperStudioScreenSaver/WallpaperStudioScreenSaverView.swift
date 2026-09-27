@preconcurrency import AVFoundation
import AppKit
import ScreenSaver
import WallpaperCore

@objc(WallpaperStudioScreenSaverView)
public final class WallpaperStudioScreenSaverView: ScreenSaverView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var imageLayer: CALayer?
    private var messageLayer: CATextLayer?
    private var loadTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var visibilityObservers: [NSObjectProtocol] = []
    private var visibilityTimer: Timer?
    private var animationIsActive = false
    private var configuredMuteVideo = true
    private var configuredVolume: Float = 0.5
    private var playbackIsRunning = false
    private var currentZoom = 1.0
    private var currentHorizontalPosition = 0.0
    private var currentVerticalPosition = 0.0

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        configureBaseView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureBaseView()
    }

    public override func startAnimation() {
        super.startAnimation()
        animationIsActive = true
        installVisibilityObservers()
        installVisibilityTimer()
        if configurationObserver == nil {
            configurationObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.wallpaperstudio.screenSaverConfigurationChanged"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reloadConfiguredMedia() }
            }
        }
        reloadConfiguredMedia()
    }

    @MainActor
    private func reloadConfiguredMedia() {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            await self?.loadConfiguredMedia()
        }
    }

    public override func stopAnimation() {
        animationIsActive = false
        loadTask?.cancel()
        loadTask = nil
        stopPlaybackImmediately()
        player?.pause()
        looper?.disableLooping()
        playerLayer?.removeFromSuperlayer()
        imageLayer?.removeFromSuperlayer()
        messageLayer?.removeFromSuperlayer()
        player = nil
        looper = nil
        playerLayer = nil
        imageLayer = nil
        messageLayer = nil
        if let configurationObserver {
            DistributedNotificationCenter.default().removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        removeVisibilityObservers()
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        super.stopAnimation()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopPlaybackImmediately()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePlaybackForVisibility()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        stopPlaybackImmediately()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePlaybackForVisibility()
    }

    public override func animateOneFrame() {}

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutMediaLayer(playerLayer)
        layoutMediaLayer(imageLayer)
        updateMessageFrame()
    }

    private func configureBaseView() {
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }

    @MainActor
    private func loadConfiguredMedia() async {
        clearMediaLayers()
        do {
            let store = ScreenSaverRuntimeStore.sharedForCurrentUser()
            guard let content = try store.load() else {
                showMessage("Choose Screen Saver content in Wallpaper Studio.")
                return
            }
            let configuration = content.configuration
            if !isPreview, case let .display(selectedID) = configuration.displayTarget {
                guard let screen = window?.screen,
                      DisplayCatalog.persistentID(for: screen) == selectedID
                else {
                    // ScreenSaverEngine creates one host per display. Excluded hosts stay
                    // silent and neutral instead of duplicating content or diagnostics.
                    return
                }
            }
            guard !Task.isCancelled else { return }

            if configuration.mediaKind == .video {
                let asset = AVURLAsset(url: content.mediaURL)
                guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                    throw ScreenSaverRuntimeError.missingMedia
                }
                showVideo(content.mediaURL, configuration: configuration)
            } else {
                showImage(content.mediaURL, configuration: configuration)
            }
        } catch {
            showMessage(error.localizedDescription)
        }
    }

    @MainActor
    private func showVideo(
        _ url: URL,
        configuration: ScreenSaverRuntimeConfiguration
    ) {
        setPlacement(from: configuration)
        let queue = AVQueuePlayer()
        configuredMuteVideo = configuration.muteVideo
        configuredVolume = Float(min(1, max(0, configuration.volume)))
        queue.isMuted = true
        queue.volume = configuredVolume
        queue.actionAtItemEnd = .none
        queue.automaticallyWaitsToMinimizeStalling = false
        queue.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 5
        let backingScale = window?.screen?.backingScaleFactor ?? 2
        item.preferredMaximumResolution = CGSize(
            width: max(1, bounds.width * backingScale),
            height: max(1, bounds.height * backingScale)
        )
        let loop = AVPlayerLooper(player: queue, templateItem: item)
        let videoLayer = AVPlayerLayer(player: queue)
        videoLayer.videoGravity = Self.videoGravity(for: configuration.scaling)
        videoLayer.drawsAsynchronously = true
        layoutMediaLayer(videoLayer)
        layer?.addSublayer(videoLayer)
        player = queue
        looper = loop
        playerLayer = videoLayer
        updatePlaybackForVisibility()
        DispatchQueue.main.async { [weak self] in
            self?.updatePlaybackForVisibility()
        }
    }

    @MainActor
    private func showImage(
        _ url: URL,
        configuration: ScreenSaverRuntimeConfiguration
    ) {
        guard let image = NSImage(contentsOf: url) else { return }
        setPlacement(from: configuration)
        let contentLayer = CALayer()
        contentLayer.contents = image
        contentLayer.contentsGravity = Self.contentsGravity(for: configuration.scaling)
        contentLayer.masksToBounds = true
        layoutMediaLayer(contentLayer)
        layer?.addSublayer(contentLayer)
        imageLayer = contentLayer
    }

    @MainActor
    private func clearMediaLayers() {
        stopPlaybackImmediately()
        looper?.disableLooping()
        playerLayer?.removeFromSuperlayer()
        imageLayer?.removeFromSuperlayer()
        messageLayer?.removeFromSuperlayer()
        player = nil
        looper = nil
        playerLayer = nil
        imageLayer = nil
        messageLayer = nil
    }

    private func installVisibilityObservers() {
        guard visibilityObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ]
        visibilityObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updatePlaybackForVisibility() }
            }
        }
        visibilityObservers.append(
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateAudioForVisibility() }
            }
        )
        visibilityObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.stopPlaybackImmediately() }
            }
        )
        visibilityObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updatePlaybackForVisibility() }
            }
        )
    }

    private func removeVisibilityObservers() {
        for observer in visibilityObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        visibilityObservers.removeAll()
    }

    private func installVisibilityTimer() {
        visibilityTimer?.invalidate()
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.window?.isVisible != true || self.isHiddenOrHasHiddenAncestor {
                    self.stopPlaybackImmediately()
                } else {
                    self.updateAudioForVisibility()
                }
            }
        }
        if let visibilityTimer {
            RunLoop.main.add(visibilityTimer, forMode: .common)
        }
    }

    private func updatePlaybackForVisibility() {
        guard let player else { return }
        // Do not use `occlusionState` here. The authentication controls are
        // intentionally above the Screen Saver and can make the host report
        // transient occlusion, which used to pause/resume AVPlayer repeatedly.
        let windowIsVisible = window?.isVisible == true
        guard animationIsActive, windowIsVisible, !isHiddenOrHasHiddenAncestor else {
            stopPlaybackImmediately()
            return
        }
        player.volume = configuredVolume
        guard !playbackIsRunning else { return }
        playbackIsRunning = true
        player.playImmediately(atRate: 1)
        updateAudioForVisibility()
    }

    /// Occlusion only controls audio. Video keeps decoding so authentication
    /// overlays cannot cause a pause/resume loop and low frame rate.
    private func updateAudioForVisibility() {
        guard let player else { return }
        let isActuallyVisible = animationIsActive
            && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor
        player.volume = configuredVolume
        player.isMuted = configuredMuteVideo || !isActuallyVisible
    }

    private func stopPlaybackImmediately() {
        playbackIsRunning = false
        player?.isMuted = true
        player?.pause()
    }

    private func setPlacement(from configuration: ScreenSaverRuntimeConfiguration) {
        currentZoom = min(3, max(0.5, configuration.zoom))
        currentHorizontalPosition = min(1, max(-1, configuration.horizontalPosition))
        currentVerticalPosition = min(1, max(-1, configuration.verticalPosition))
    }

    private func layoutMediaLayer(_ mediaLayer: CALayer?) {
        guard let mediaLayer else { return }
        mediaLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        mediaLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        var placement = CGAffineTransform(
            scaleX: CGFloat(currentZoom),
            y: CGFloat(currentZoom)
        )
        placement.tx = CGFloat(currentHorizontalPosition) * bounds.width * 0.5
        placement.ty = CGFloat(currentVerticalPosition) * bounds.height * 0.5
        mediaLayer.setAffineTransform(placement)
    }

    @MainActor
    private func showMessage(_ message: String) {
        let textLayer = CATextLayer()
        textLayer.string = message
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        textLayer.fontSize = isPreview ? 12 : 22
        textLayer.contentsScale = window?.screen?.backingScaleFactor ?? 2
        textLayer.isWrapped = true
        layer?.addSublayer(textLayer)
        messageLayer = textLayer
        updateMessageFrame()
    }

    private func updateMessageFrame() {
        let height: CGFloat = isPreview ? 42 : 80
        messageLayer?.frame = CGRect(
            x: bounds.minX + 24,
            y: bounds.midY - height / 2,
            width: max(0, bounds.width - 48),
            height: height
        )
    }

    private static func videoGravity(for scaling: ContentScaling) -> AVLayerVideoGravity {
        switch scaling {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }

    private static func contentsGravity(for scaling: ContentScaling) -> CALayerContentsGravity {
        switch scaling {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }
}
