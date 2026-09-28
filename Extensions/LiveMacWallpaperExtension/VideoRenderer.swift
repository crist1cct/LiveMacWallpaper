import AVFoundation
import CoreMedia
import ObjectiveC
import os

/// Call AVSampleBufferDisplayLayer's private `_setDisallowsVideoLayerDisplayCompositing:`
/// (a BOOL setter Apple's WallpaperExtensionKit uses on every AVSBDL). Resolved via the
/// ObjC runtime so the private selector never appears in a header; a no-op if the API
/// ever disappears. Prevents the layer painting opaque black before its first frame.
private func setDisallowsVideoLayerDisplayCompositing(_ layer: CALayer, _ flag: Bool) {
    let sel = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: sel),
          let imp = class_getMethodImplementation(type(of: layer), sel) else { return }
    typealias SetBoolFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(imp, to: SetBoolFn.self)(layer, sel, ObjCBool(flag))
}

/// Plays one clip on one display surface.
///
/// Video: `AVAssetReader` → `AVSampleBufferDisplayLayer`, gapless loops by offsetting
/// sample timestamps. Audio: the SAME reader also decodes the clip's audio track to
/// LPCM and feeds an `AVSampleBufferAudioRenderer`. The layer's video renderer and the
/// audio renderer are attached to one `AVSampleBufferRenderSynchronizer`, so picture and
/// sound share a single clock driven by the audio hardware. There is no second player
/// to keep in sync, no drift correction and no seeking.
final class VideoRenderer: @unchecked Sendable {
    /// Process-wide instance counter so log lines can be attributed to a specific
    /// renderer object (to catch stale/duplicate renderers from acquire races).
    private static let idCounter = OSAllocatedUnfairLock(initialState: 0)
    let debugID: Int = VideoRenderer.idCounter.withLock { $0 += 1; return $0 }

    let displayLayer: AVSampleBufferDisplayLayer
    /// Read-only view of the playback clock (the synchronizer's timebase). Mutate it
    /// only through `setClockRate` / `setClockTime`.
    let timebase: CMTimebase
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let renderer: AVSampleBufferVideoRenderer
    private let stillFrameLayer: CALayer
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    /// First audio track of `asset`, if the clip has sound.
    private var audioTrack: AVAssetTrack?
    /// End of the video track in clip time. Audio past this point is cut so the next
    /// loop's audio never overlaps the previous one.
    private var clipEnd: CMTime
    private let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)
    private var isRunning = true
    private(set) var isPaused = false
    private var currentPolicy: PlaybackPolicy = .full
    private var rampTimer: (any DispatchSourceTimer)?
    private var deepPauseTimer: (any DispatchSourceTimer)?

    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?

    // Audio path — all touched only on `queue`.
    private var currentAudioOutput: AVAssetReaderTrackOutput?
    private var nextAudioOutput: AVAssetReaderTrackOutput?
    private var nextTracks: TrackSet?
    /// Next audio buffer, already offset onto the running timeline, not yet enqueued.
    private var pendingAudio: CMSampleBuffer?
    /// Whether this renderer's audio should be audible (the lock-screen audio owner).
    private var audioActive = false
    private var audioVolume: Float = 1
    /// 0…1 envelope applied on top of `audioVolume`.
    private var audioGain: Double = 0
    private var audioFadeTimer: (any DispatchSourceTimer)?

    /// A renderer `flush` (decoder reset) is the one async hop in the pipeline, and
    /// TWO overlapping flushes corrupt the renderer (rapid-switch breakage). These two
    /// flags — touched ONLY on `queue` — serialize it: at most one flush is ever in
    /// flight, and a switch arriving during a flush is coalesced, so when the flush
    /// completes we restart once to whatever the latest selected asset is.
    private var flushInFlight = false
    private var restartPending = false

    /// Diagnostic: number of remaining feed-loop ticks to log after a restart.
    private var feedLogBudget = 0

    // Gapless looping state.
    // ptsOffset accumulates across loops so both DTS and PTS are monotonically increasing.
    // lastEnqueuedEnd tracks the highest sample end time (max, not last — handles B-frames).
    private var ptsOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero

    /// Timebase positions (seconds) at which each loop of the clip begins. Written on
    /// `queue`, read from any thread by the lock-screen audio clock. A loop start is
    /// recorded when the NEXT loop is enqueued, i.e. slightly ahead of the display, so
    /// readers pick the latest start that is not in the future.
    private let loopClock = OSAllocatedUnfairLock(initialState: LoopClockState())

    private struct LoopClockState: Sendable {
        var starts: [Double] = [0]
        /// Bumped whenever the timeline is rebuilt from scratch (new clip, error reset).
        var generation = 0
        var assetURL: URL?
    }

    /// Tracks of one asset, loaded together.
    struct TrackSet: @unchecked Sendable {
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let clipEnd: CMTime
    }

    /// Readers are built with both outputs so audio and video come from one decode pass.
    private struct ReaderSet {
        let reader: AVAssetReader
        let video: AVAssetReaderTrackOutput
        let audio: AVAssetReaderTrackOutput?
    }

    /// Interleaved 32-bit float PCM at the source rate and channel layout.
    private static var audioOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// How far ahead of the clock audio is queued while audible.
    private static let audioLead: Double = 1.0
    private static let audioFadeInDuration: Double = 0.5
    private static let audioFadeOutDuration: Double = 0.15
    private static let audioFadeInterval: TimeInterval = 1.0 / 100.0
    /// The picture must run at (nearly) normal speed before sound is let through.
    private static let audibleRate: Double = 0.97

    /// Called at each loop boundary to select the video URL for the next iteration.
    var variantSelector: (@Sendable () -> URL)?

    static func create(
        rootLayer: CALayer,
        videoURL: URL,
        stillImage: CGImage? = nil,
    ) async throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        guard let tracks = await loadTracks(asset) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale
        // Opaque: the per-surface context fix (each Space/lock surface owns its own
        // CAContext) is what stops the black, not this layer's opacity. Leaving the
        // layer non-opaque only adds a per-frame blend against what's behind it, which
        // makes the layer visibly blink while the compositor rebuilds it during a
        // switch. Opaque keeps the switch seamless.
        displayLayer.isOpaque = true
        // Match Apple's WallpaperExtensionKit: stop the AVSampleBufferDisplayLayer from
        // painting opaque BLACK before its first frame is composited. On a cold start the
        // Agent hosts our context the instant we reply, and without this an as-yet-empty
        // layer flashes black (the residual "black still"). Apple sets this on every AVSBDL.
        setDisallowsVideoLayerDisplayCompositing(displayLayer, true)
        // Added to the tree in init() inside an action-free transaction (below).

        return VideoRenderer(
            rootLayer: rootLayer,
            displayLayer: displayLayer,
            asset: asset,
            tracks: tracks,
            stillImage: stillImage,
        )
    }

    private init(
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer,
        asset: AVURLAsset,
        tracks: TrackSet,
        stillImage: CGImage?,
    ) {
        self.displayLayer = displayLayer
        self.renderer = displayLayer.sampleBufferRenderer
        self.asset = asset
        self.videoTrack = tracks.video
        self.audioTrack = tracks.audio
        self.clipEnd = tracks.clipEnd

        self.stillFrameLayer = CALayer()
        stillFrameLayer.frame = rootLayer.bounds
        stillFrameLayer.contentsGravity = .resizeAspectFill
        stillFrameLayer.contentsScale = rootLayer.contentsScale
        stillFrameLayer.opacity = 0
        stillFrameLayer.name = "livemacwallpaper.stillFrame"

        // One clock for picture and sound: the layer's video renderer and the audio
        // renderer are both attached to the same synchronizer, whose timebase follows
        // the audio device clock. Every frame is presented on the audio timeline.
        self.timebase = synchronizer.timebase
        audioRenderer.volume = 0
        audioRenderer.isMuted = true
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.addRenderer(renderer)
        synchronizer.addRenderer(audioRenderer)
        // Rate stays 0 until start() — prevents the clock from advancing during the
        // async gap between init and start, which would cause the first batch of
        // frames to be considered "late" and dropped.
        synchronizer.setRate(0, time: .zero)

        // Install the layers and seed the still in ONE action-free transaction, so
        // Core Animation doesn't play an implicit "onOrderIn" animation (the video
        // appearing to zoom/fade in). The still is an IOSurface-backed sample buffer
        // at PTS 0 — unlike CALayer.contents (black when hosted cross-process) it
        // composites into WallpaperAgent's CALayerHost, so the desktop shows the
        // still immediately; the video's first real frame (also PTS 0) plays over it
        // once rate=1.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.sublayers?.filter { $0.name == "livemacwallpaper.stillFrame" }.forEach { $0.removeFromSuperlayer() }
        rootLayer.addSublayer(displayLayer)
        rootLayer.addSublayer(stillFrameLayer)
        traceLog("  [Renderer #\(debugID)] CREATED for \(asset.url.lastPathComponent), displayLayer=\(ObjectIdentifier(displayLayer)), rootLayer sublayers=\((rootLayer.sublayers?.count ?? 0))")
        if let stillImage, let stillBuffer = makeStillSampleBuffer(from: stillImage) {
            // Tag DisplayImmediately so the still is shown the instant it's enqueued,
            // rather than waiting on the control timebase (which is frozen at rate 0 here).
            // Without this the frame can sit undisplayed → the layer reads empty → black.
            Self.setDisplayImmediately(stillBuffer)
            renderer.enqueue(stillBuffer)
            traceLog("  [Renderer #\(debugID)] Seeded still into display layer (\(stillImage.width)x\(stillImage.height))")
        } else {
            traceLog("  [Renderer #\(debugID)] No still to seed (stillImage present: \(stillImage != nil))")
        }
        CATransaction.commit()
        // flush() (not just commit()) is what pushes the layer tree to the render
        // server for a REMOTE context — without it the still never reaches the
        // WindowServer and the desktop stays black until a later flush.
        CATransaction.flush()
    }

    /// Start playback: decode and enqueue the first frame, then begin the feed loop.
    /// Runs on the renderer's serial queue rather than the caller's thread — the
    /// first-frame `copyNextSampleBuffer` is a blocking decode, and the caller is a
    /// Swift-concurrency (cooperative) task; blocking a cooperative thread violates
    /// forward progress and starves the extension's tiny executor.
    ///
    /// `onFirstFrameReady`, if provided, is invoked AFTER the first frame is enqueued and
    /// flushed to the render server — i.e. once this renderer's CAContext is actually
    /// displaying video. The acquire path uses it to defer its XPC reply until the new
    /// context is live, so WallpaperAgent keeps compositing the OLD wallpaper until then
    /// and the host swap lands directly on playing video (no blink / still-flash / zoom),
    /// mirroring Apple's own extensions. It is called exactly once on every path,
    /// including early exits, so a gated reply can never hang.
    func start(onFirstFrameReady: (@Sendable () -> Void)? = nil) {
        traceLog("  [start #\(debugID)] asset=\(asset.url.lastPathComponent)")
        queue.async { [weak self] in
            guard let self else { onFirstFrameReady?(); return }
            guard isRunning else { traceLog("  [start #\(debugID)] aborted — already stopped"); onFirstFrameReady?(); return }
            guard let set = makeReaderSet(asset: asset, video: videoTrack, audio: audioTrack) else { onFirstFrameReady?(); return }
            let reader = set.reader
            let output = set.video
            reader.startReading()

            // Reset the clock BEFORE first enqueue so the frame isn't seen as late.
            setClockTime(.zero)

            // Enqueue the first frame and flush it to the render server inside an
            // action-free transaction, so the context is genuinely displaying video
            // before onFirstFrameReady fires (the deferred acquire reply gates on this).
            if let firstSample = output.copyNextSampleBuffer() {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                renderer.enqueue(firstSample)
                CATransaction.commit()
                CATransaction.flush()
            }

            currentReader = reader
            currentOutput = output
            currentAudioOutput = set.audio
            pendingAudio = nil
            ptsOffset = .zero
            lastEnqueuedEnd = .zero
            resetLoopClock()

            // Begin advancing the clock — playback starts.
            setClockRate(1.0)

            // The context now holds a live, composited video frame — release the gate so
            // the acquire can reply and the agent can swap to us.
            onFirstFrameReady?()

            prepareNextReader()
            feedFromCurrentReader()
        }
    }

    /// Switch to a different video IN PLACE, reusing this renderer's existing
    /// `displayLayer`. The layer is already attached to the display's CAContext and
    /// hosted by WallpaperAgent, so feeding it frames from a new asset updates the
    /// desktop — whereas building a fresh renderer (new `AVSampleBufferDisplayLayer`)
    /// added to an already-hosted context does NOT composite (the switch-between-
    /// videos bug). So we keep the one hosted layer and restart it on the new asset.
    ///
    /// Fully serialized on `queue`, no `Task`: the track load blocks the queue thread
    /// (a real thread we own, which already blocks for decodes). Because every switch
    /// runs to completion in FIFO order on one thread, rapid switching is naturally
    /// last-*requested*-wins with no cancellation bookkeeping — the only async hop is
    /// the renderer's `flush`, which is serialized and coalesces rapid switches.
    /// Re-frame the video + still layers to a new destination geometry (points) and
    /// backing scale — used when a display reconnects at, or switches to, a different
    /// resolution. Both layers fill the root and are `resizeAspectFill`, so re-framing
    /// them to the full bounds is all that's needed; the AVSampleBufferDisplayLayer
    /// re-fits the decoded frames to the new size on the next composite. Synchronous,
    /// inside an action-free flushed transaction, to match the acquire path's own layer
    /// mutations (which run on the same Lifecycle queue, off the main thread).
    func resize(to destSize: CGSize, scale: CGFloat) {
        let bounds = CGRect(origin: .zero, size: destSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.contentsScale = scale
        stillFrameLayer.frame = bounds
        stillFrameLayer.contentsScale = scale
        CATransaction.commit()
        CATransaction.flush()
        traceLog("  [resize #\(debugID)] → \(destSize) @\(scale)x")
    }

    func switchVideo(to url: URL) {
        traceLog("  [switchVideo #\(debugID)] REQUEST target=\(url.lastPathComponent)")
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            // Same file already playing → nothing to do (defuses repeated identical picks).
            if asset.url == url {
                traceLog("  [switchVideo #\(debugID)] DEDUP: already on \(url.lastPathComponent)")
                return
            }
            let newAsset = AVURLAsset(url: url)
            guard let tracks = Self.loadTracksBlocking(newAsset) else {
                traceLog("  [switchVideo #\(debugID)] no video track in \(url.lastPathComponent)")
                return
            }
            asset = newAsset
            adopt(tracks)
            traceLog("  [switchVideo #\(debugID)] restarting from 0 → \(url.lastPathComponent)")
            restartWithCurrentAsset()
        }
    }

    /// Tag a sample buffer so the renderer displays it immediately, replacing all
    /// previously enqueued/displayed images regardless of timestamps (per
    /// AVQueuedSampleBufferRendering docs). Used for the first frame of a switched
    /// video so the swap is instant and doesn't wait on the control timebase.
    private static func setDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
        let count = CFArrayGetCount(attachments)
        for i in 0 ..< count {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
            )
        }
    }

    /// Load the video track, the first audio track and the video's end time.
    private static func loadTracks(_ asset: AVURLAsset) async -> TrackSet? {
        guard let video = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let audio = (try? await asset.loadTracks(withMediaType: .audio))?.first
        let range = try? await video.load(.timeRange)
        let end = range.map { CMTimeRangeGetEnd($0) } ?? .invalid
        return TrackSet(video: video, audio: audio, clipEnd: end.isNumeric ? end : .invalid)
    }

    private final class TrackBox: @unchecked Sendable {
        let asset: AVURLAsset
        var result: TrackSet?
        init(asset: AVURLAsset) { self.asset = asset }
    }

    /// Blocking variant for the renderer's serial `queue`: it blocks that (real, owned)
    /// thread while AVFoundation loads the tracks, so there's no cooperative-executor
    /// starvation and switches stay strictly ordered. Local files load in a few ms.
    private static func loadTracksBlocking(_ asset: AVURLAsset) -> TrackSet? {
        traceLog("  [load] blocking-load START \(asset.url.lastPathComponent)")
        let box = TrackBox(asset: asset)
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.result = await VideoRenderer.loadTracks(box.asset)
            sem.signal()
        }
        sem.wait()
        traceLog("  [load] blocking-load DONE \(asset.url.lastPathComponent) video=\(box.result != nil) audio=\(box.result?.audio != nil)")
        return box.result
    }

    /// Make `tracks` the current clip's tracks. Must run on `queue`.
    private func adopt(_ tracks: TrackSet) {
        videoTrack = tracks.video
        audioTrack = tracks.audio
        clipEnd = tracks.clipEnd
    }

    /// Build a reader with a video output and, when the clip has sound, an LPCM audio
    /// output. `start` limits reading to the clip from that time on.
    private func makeReaderSet(
        asset: AVURLAsset,
        video: AVAssetTrack,
        audio: AVAssetTrack?,
        from start: CMTime? = nil,
    ) -> ReaderSet? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        if let start {
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audio {
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: Self.audioOutputSettings)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }
        return ReaderSet(reader: reader, video: videoOutput, audio: audioOutput)
    }

    // MARK: - Clock

    /// All clock changes go through the synchronizer so the audio renderer follows.
    private func setClockRate(_ rate: Double) {
        synchronizer.rate = Float(rate)
    }

    private func setClockTime(_ time: CMTime) {
        synchronizer.setRate(synchronizer.rate, time: time)
    }

    /// Stop playback. Dispatches synchronously to the renderer queue to ensure
    /// no callback is mid-flight before canceling the reader.
    func stop() {
        extensionLog("  [stop #\(debugID)] stopping renderer for \(asset.url.lastPathComponent)")
        cancelDeepPauseTimer()
        silenceAudioNow()
        queue.sync {
            isRunning = false
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
            stopAudioFade()
            audioActive = false
            pendingAudio = nil
            currentAudioOutput = nil
            nextAudioOutput = nil
            audioRenderer.flush()
            synchronizer.setRate(0, time: CMTimebaseGetTime(timebase))
        }
        // Clean up layers from the layer tree
        displayLayer.removeFromSuperlayer()
        stillFrameLayer.removeFromSuperlayer()
    }

    var playbackTimeSeconds: Double {
        CMTimebaseGetTime(timebase).seconds
    }

    /// Loop start in effect at `time` (timebase seconds).
    private func loopStartSeconds(at time: Double) -> Double {
        loopClock.withLock { state in
            state.starts.last(where: { $0 <= time + 0.0005 }) ?? state.starts.first ?? 0
        }
    }

    /// New timeline beginning at `start` seconds. Must run on `queue`.
    private func resetLoopClock(start: Double = 0, newTimeline: Bool = true) {
        let url = asset.url
        loopClock.withLock { state in
            state.starts = [start]
            state.assetURL = url
            if newTimeline { state.generation &+= 1 }
        }
    }

    /// The next loop begins at `start` seconds on the same timeline. Must run on `queue`.
    private func recordLoopStart(_ start: Double) {
        let url = asset.url
        loopClock.withLock { state in
            if let last = state.starts.last, start <= last { return }
            state.starts.append(start)
            if state.starts.count > 4 { state.starts.removeFirst(state.starts.count - 4) }
            state.assetURL = url
        }
    }


    func pause() {
        guard !isPaused else { return }
        traceLog("  [pause #\(debugID)]")
        isPaused = true
        cancelRamp()
        setClockRate(0.0)
        generateStillFrame()
        scheduleDeepPause()
    }

    func resume() {
        guard isPaused else { return }
        traceLog("  [resume #\(debugID)] currentReader=\(currentReader == nil ? "nil(deep)" : "live") asset=\(asset.url.lastPathComponent) rate→1")
        isPaused = false
        cancelRamp()
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0
        if currentReader == nil {
            // Woke from deep pause — readers were freed. Recreate CONTINUING from the paused
            // position (seamless, no black) so a screen-lock/display-sleep wake resumes the
            // same video instead of restarting it.
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                recreatePlayback(seamlessResume: true)
                setClockRate(1.0)
            }
        } else {
            setClockRate(1.0)
        }
    }

    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false) {
        guard policy != currentPolicy else { return }
        let oldPolicy = currentPolicy
        currentPolicy = policy
        extensionLog("  [applyPolicy #\(debugID)] \(oldPolicy) → \(policy) animated=\(animated) asset=\(asset.url.lastPathComponent)")

        switch policy {
        case .paused:
            if animated {
                rampDown()
            } else {
                pause()
            }
        case .full, .reduced, .minimal:
            if animated {
                rampUp()
            } else {
                resume()
            }
        }
    }

    // MARK: - Ramp (Apple-like lock screen transition)

    /// Ramp durations in seconds and step interval aligned to display refresh rate.
    /// Ramp-down (unlock → desktop pause) matches the ~6 s deceleration of Apple's
    /// built-in wallpapers after unlock; ramp-up (→ lock screen) stays short so
    /// playback reaches full speed while the lock reveal is still on screen.
    private static let rampUpDuration: TimeInterval = 2.0
    private static let rampDownDuration: TimeInterval = 6.0
    private static let rampStepInterval: TimeInterval = 1.0 / 120.0

    /// Gradually reduce the timebase rate to zero, then freeze.
    ///
    /// `isPaused` flips immediately — it is the logical state, the rate follows.
    /// With it flipped at ramp COMPLETION instead, a resume arriving mid-ramp hit
    /// resume()/rampUp()'s `isPaused` guards and did nothing, stranding the rate
    /// wherever the cancelled ramp left it (visibly slow-motion playback).
    private func rampDown() {
        guard !isPaused else { return }
        isPaused = true
        cancelDeepPauseTimer()
        ramp(to: 0.0, over: Self.rampDownDuration) { [weak self] in
            guard let self else { return }
            generateStillFrame()
            scheduleDeepPause()
        }
    }

    /// Gradually raise the timebase rate to 1.0 — from wherever it is now, so
    /// reversing a mid-flight ramp-down accelerates from the current speed.
    private func rampUp() {
        guard isPaused else { return }
        isPaused = false
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0

        if currentReader == nil {
            // Deep-paused: no frames to ramp into. Wake instantly (continuing from the paused
            // position, seamless) instead of running a ramp against an empty pipeline.
            cancelRamp()
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                recreatePlayback(seamlessResume: true)
                setClockRate(1.0)
            }
            return
        }

        ramp(to: 1.0, over: Self.rampUpDuration)
    }

    /// Ease the timebase rate from its CURRENT value to `target`.
    ///
    /// Starting from the live rate is what makes ramps reversible: a reversal
    /// mid-flight travels the remaining distance in proportionally less time,
    /// keeping the rate curve continuous instead of replaying a full schedule
    /// from 1.0 or 0 (which made a paused wallpaper leap to speed and decelerate).
    private func ramp(to target: Double, over fullDuration: TimeInterval, then completion: (@Sendable () -> Void)? = nil) {
        cancelRamp()
        let start = Double(CMTimebaseGetRate(timebase))
        let distance = abs(target - start)
        guard distance > 0.001 else {
            setClockRate(target)
            completion?()
            return
        }
        let totalSteps = RampMath.steps(distance: distance, fullDuration: fullDuration, stepInterval: Self.rampStepInterval)
        var step = 0

        // First step lands immediately so a resume never sits on a dead frame.
        if target > start {
            setClockRate(max(start, 0.01))
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let rate = RampMath.rate(from: start, to: target, progress: progress)
            setClockRate(rate)

            if step >= totalSteps {
                timer.cancel()
                rampTimer = nil
                completion?()
            }
        }
        rampTimer = timer
        timer.resume()
    }

    private func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    // MARK: - Deep Pause

    //
    // After a sustained pause (lock screen overnight, brightness at zero, etc.)
    // the asset reader still holds decoded buffers and the underlying video
    // decoder. Tearing them down frees memory and lets the system fully idle.
    // On resume we recreate the pipeline from scratch via `recreatePlayback()`.

    private static let deepPauseDelay: TimeInterval = 30

    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in
            self?.enterDeepPause()
        }
        deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    /// Runs on the renderer queue when the deep-pause timer fires.
    private func enterDeepPause() {
        deepPauseTimer = nil
        guard isRunning, isPaused, currentReader != nil else { return }
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        currentAudioOutput = nil
        nextAudioOutput = nil
        nextTracks = nil
        pendingAudio = nil
        audioRenderer.flush()
        extensionLog("  [Renderer] Deep-paused — freed asset readers")
    }

    /// Rebuild the playback pipeline on the renderer queue. Two modes:
    /// - `seamlessResume: true` (deep-pause wake): CONTINUE from the paused timebase
    ///   position, keeping the last frame on screen — no black flash, no restart-from-0.
    ///   This is what a screen-lock/display-sleep wake uses so the video resumes where it
    ///   left off (Kiri: "show the same video continuously", not blink-and-restart).
    /// - `seamlessResume: false` (error recovery): hard reset to time 0 and clear the
    ///   (possibly corrupt) displayed frame.
    /// Caller restores the timebase rate.
    private func recreatePlayback(seamlessResume: Bool = false) {
        traceLog("  [recreatePlayback #\(debugID)] seamless=\(seamlessResume) asset=\(asset.url.lastPathComponent)")
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil
        nextAudioOutput = nil
        nextTracks = nil
        pendingAudio = nil
        audioRenderer.flush()

        let resumeTime = CMTimebaseGetTime(timebase)
        let continuing = seamlessResume && resumeTime.isNumeric && resumeTime > .zero
        // The timebase keeps counting across loops, so the paused spot INSIDE the clip is
        // the timebase position minus the start of the loop that was on screen. Reading
        // from the raw timebase position overshot the clip after the first loop, the
        // reader came back empty and playback (and its audio) jumped to the clip start.
        let loopStart = continuing
            ? CMTime(seconds: loopStartSeconds(at: resumeTime.seconds), preferredTimescale: resumeTime.timescale)
            : .zero
        let clipPosition = continuing ? CMTimeMaximum(.zero, CMTimeSubtract(resumeTime, loopStart)) : .zero
        // Keep the last displayed frame when continuing (no black); clear it on error reset.
        renderer.flush(removingDisplayedImage: !continuing)

        // Resume reading from the paused position (AVAssetReader seeks to the enclosing
        // keyframe and emits from here) so playback continues instead of restarting.
        guard let set = makeReaderSet(
            asset: asset,
            video: videoTrack,
            audio: audioTrack,
            from: continuing ? clipPosition : nil
        ) else {
            extensionLog("  [recreatePlayback] FAILED to create AVAssetReader for \(asset.url.lastPathComponent)")
            currentReader = nil
            currentOutput = nil
            currentAudioOutput = nil
            return
        }
        let reader = set.reader
        let output = set.video
        reader.startReading()
        currentReader = reader
        currentOutput = output
        currentAudioOutput = set.audio

        // Samples keep their place on the running timeline: clip time + loop start.
        ptsOffset = loopStart
        lastEnqueuedEnd = continuing ? resumeTime : .zero
        if continuing {
            resetLoopClock(start: loopStart.seconds, newTimeline: false)
        } else {
            setClockTime(.zero)
            resetLoopClock()
        }

        // Enqueue the first frame tagged DisplayImmediately so it replaces the held frame the
        // instant it decodes — seamless when continuing, and no wait-on-timebase on reset.
        if let raw = output.copyNextSampleBuffer() {
            let first = offsetTimingForLoop(raw)
            Self.setDisplayImmediately(first)
            renderer.enqueue(first)
            let pts = CMSampleBufferGetPresentationTimeStamp(first)
            let dur = CMSampleBufferGetDuration(first)
            if pts.isValid {
                let end = dur.isValid && dur > .zero
                    ? CMTimeAdd(pts, dur)
                    : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                lastEnqueuedEnd = CMTimeMaximum(lastEnqueuedEnd, end)
            }
        }

        prepareNextReader()
        feedFromCurrentReader()
    }

    /// Restart playback on the already-set `asset`/`videoTrack` from time 0 — the
    /// video changed, so there's no timeline to preserve (that's only for gapless
    /// looping of the SAME clip). This is `start()`'s sequence applied to a live
    /// renderer: freeze the clock (rate 0) so the fresh PTS-0 frames aren't judged
    /// "late", async-flush the decoder (a `flush` is a decoder RESET and discards
    /// anything enqueued before it completes — that was the "no reaction" bug), then
    /// in the completion reset the timeline to 0, enqueue the first IDR frame, and
    /// resume at rate 1. `removingDisplayedImage:false` holds the last frame (no
    /// black) until that first frame lands. Must run on `queue`.
    private func restartWithCurrentAsset() {
        // Serialize the decoder reset: if a flush is already in flight, just mark that
        // a restart is wanted. When that flush completes it will restart to whatever
        // `asset` is by then (the latest pick) — so rapid switching coalesces to one
        // reset per settle, never two overlapping flushes.
        traceLog("  [restart #\(debugID)] ENTER flushInFlight=\(flushInFlight) restartPending=\(restartPending) asset=\(asset.url.lastPathComponent)")
        if flushInFlight {
            restartPending = true
            traceLog("  [restart #\(debugID)] flush in flight → coalescing to latest (\(asset.url.lastPathComponent))")
            return
        }
        flushInFlight = true
        // Freeze the clock up front so it can't advance past PTS 0 during the async
        // flush — otherwise the first frames arrive "late" and get dropped.
        setClockRate(0.0)
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil
        nextAudioOutput = nil
        nextTracks = nil
        currentAudioOutput = nil
        pendingAudio = nil
        audioRenderer.flush()

        traceLog("  [restart #\(debugID)] flushing decoder for \(asset.url.lastPathComponent)")
        // Keep the currently displayed frame (no blank) — the first new frame below is
        // tagged DisplayImmediately, which replaces it the instant it decodes.
        renderer.flush(removingDisplayedImage: false) { [weak self] in
            guard let self else { extensionLog("  [restart] FLUSH-CB but self gone (flushInFlight leaks!)"); return }
            traceLog("  [restart #\(debugID)] FLUSH-CB fired (rendererStatus=\(renderer.status.rawValue)) → hop to queue")
            queue.async { [weak self] in
                guard let self else { return }
                flushInFlight = false
                traceLog("  [restart #\(debugID)] FLUSH-CB on queue: flushInFlight→false, restartPending=\(restartPending), asset=\(asset.url.lastPathComponent), isRunning=\(isRunning)")
                // Switches arrived during the flush → do exactly one more restart to
                // the newest asset, instead of feeding this (now stale) one.
                if restartPending {
                    restartPending = false
                    traceLog("  [restart #\(debugID)] coalesced → restarting to \(asset.url.lastPathComponent)")
                    restartWithCurrentAsset()
                    return
                }
                guard isRunning else { return }
                guard let set = makeReaderSet(asset: asset, video: videoTrack, audio: audioTrack) else {
                    extensionLog("  [restart #\(debugID)] FAILED to create AVAssetReader for \(asset.url.lastPathComponent)")
                    currentReader = nil
                    currentOutput = nil
                    return
                }
                let reader = set.reader
                let output = set.video
                reader.startReading()
                currentReader = reader
                currentOutput = output
                currentAudioOutput = set.audio
                pendingAudio = nil

                // Fresh timeline from 0.
                ptsOffset = .zero
                lastEnqueuedEnd = .zero
                setClockTime(.zero)
                resetLoopClock()

                // Enqueue the first (IDR) frame while the clock is still frozen, exactly
                // like start(), so it isn't dropped as late. Tag it DisplayImmediately so
                // it replaces the retained old frame the moment it decodes — an instant,
                // blank-free swap that doesn't depend on the timebase (important since a
                // switch can land while paused, rate=0).
                if let first = output.copyNextSampleBuffer() {
                    Self.setDisplayImmediately(first)
                    renderer.enqueue(first)
                    let pts = CMSampleBufferGetPresentationTimeStamp(first)
                    let dur = CMSampleBufferGetDuration(first)
                    if pts.isValid {
                        lastEnqueuedEnd = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                    }
                }

                setClockRate(isPaused ? 0.0 : 1.0)
                traceLog("  [restart #\(debugID)] playing \(asset.url.lastPathComponent) rate=\(isPaused ? 0 : 1) rendererStatus=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) readerStatus=\(reader.status.rawValue) err=\(renderer.error?.localizedDescription ?? "-")")
                feedLogBudget = 4
                prepareNextReader()
                feedFromCurrentReader()
            }
        }
    }

    // MARK: - Preloaded Loop Reader

    private func prepareNextReader() {
        // Deferred to a separate queue job so the (brief, blocking) variant track load
        // doesn't stall whatever called us — but still strictly ordered on `queue`,
        // no Task.
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            let nextURL = variantSelector?()
            if let nextURL, nextURL != asset.url {
                let newAsset = AVURLAsset(url: nextURL)
                guard let tracks = Self.loadTracksBlocking(newAsset) else {
                    traceLog("  [Renderer] No video track in variant: \(nextURL.lastPathComponent)")
                    return
                }
                installNextReader(asset: newAsset, tracks: tracks)
            } else {
                installNextReader(
                    asset: asset,
                    tracks: TrackSet(video: videoTrack, audio: audioTrack, clipEnd: clipEnd)
                )
            }
        }
    }

    /// Build an asset reader on the renderer queue and store it as the
    /// preloaded next reader. Must run on `queue`.
    private func installNextReader(asset: AVURLAsset, tracks: TrackSet) {
        guard let set = makeReaderSet(asset: asset, video: tracks.video, audio: tracks.audio) else {
            traceLog("  [Renderer] Failed to create next reader")
            return
        }
        nextReader = set.reader
        nextOutput = set.video
        nextAudioOutput = set.audio
        nextTracks = tracks
    }

    /// Swap to the preloaded next reader at a loop boundary.
    /// Uses timing offset for gapless continuation — no flush, no timebase reset.
    private func swapToNextReader() {
        renderer.stopRequestingMediaData()

        // Advance offset so the next loop's DTS/PTS continue the timeline.
        ptsOffset = lastEnqueuedEnd
        recordLoopStart(ptsOffset.seconds)

        // Whatever audio the finished loop still had is past the clip end; drop it so
        // the next loop's sound starts exactly where its picture starts.
        pendingAudio = nil

        if let nr = nextReader, let no = nextOutput {
            if let nrAsset = nr.asset as? AVURLAsset, nrAsset.url != asset.url {
                asset = nrAsset
                traceLog("  [Renderer] Switched variant: \(nrAsset.url.lastPathComponent)")
            }
            if let tracks = nextTracks { adopt(tracks) }
            currentReader = nr
            currentOutput = no
            currentAudioOutput = nextAudioOutput
            nextReader = nil
            nextOutput = nil
            nextAudioOutput = nil
            nextTracks = nil
        } else {
            traceLog("  [Renderer] Next reader not ready, creating synchronously")
            guard let set = makeReaderSet(asset: asset, video: videoTrack, audio: audioTrack) else {
                traceLog("  [Renderer] Failed to create fallback reader")
                return
            }
            currentReader = set.reader
            currentOutput = set.video
            currentAudioOutput = set.audio
        }

        currentReader?.startReading()

        prepareNextReader()
        feedFromCurrentReader()
    }

    // MARK: - Playback Loop

    private func feedFromCurrentReader() {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, isRunning else {
                self?.renderer.stopRequestingMediaData()
                return
            }

            // Unrecoverable failure — full reset.
            // Dispatch async: requestMediaDataWhenReady is not reentrant.
            if renderer.status == .failed {
                extensionLog("  [Renderer] Status failed: \(renderer.error?.localizedDescription ?? "unknown"), recovering")
                renderer.stopRequestingMediaData()
                queue.async { [weak self] in
                    self?.recoverFromError()
                }
                return
            }

            // Decoder hit a discontinuity or error — flush and continue feeding.
            if renderer.requiresFlushToResumeDecoding {
                traceLog("  [feed #\(debugID)] requiresFlushToResumeDecoding=YES → renderer.flush() (frames enqueued after may be discarded); status=\(renderer.status.rawValue)")
                renderer.flush()
            }

            var enqueuedThisTick = 0
            while renderer.isReadyForMoreMediaData {
                if let sample = currentOutput?.copyNextSampleBuffer() {
                    let adjusted = offsetTimingForLoop(sample)
                    enqueuedThisTick += 1

                    // Track the highest end time (max handles B-frame reordering).
                    // Some containers emit padding samples with invalid PTS — skip those
                    // to prevent NaN from poisoning the timeline offset.
                    let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
                    let dur = CMSampleBufferGetDuration(adjusted)
                    if pts.isValid {
                        let sampleEnd = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                        if sampleEnd > lastEnqueuedEnd {
                            lastEnqueuedEnd = sampleEnd
                        }
                    }

                    renderer.enqueue(adjusted)
                    pumpAudio()
                } else {
                    // Dispatch async: requestMediaDataWhenReady is not reentrant.
                    if feedLogBudget > 0 {
                        traceLog("  [feed #\(debugID)] reader exhausted after enqueuing this tick=\(enqueuedThisTick); status=\(renderer.status.rawValue) → swapToNextReader")
                    }
                    renderer.stopRequestingMediaData()
                    queue.async { [weak self] in
                        self?.swapToNextReader()
                    }
                    return
                }
            }
            pumpAudio()
            if feedLogBudget > 0 {
                feedLogBudget -= 1
                traceLog("  [feed #\(debugID)] tick enqueued=\(enqueuedThisTick) status=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) ready=\(renderer.isReadyForMoreMediaData) timebase=\(CMTimebaseGetTime(timebase).seconds)")
            }
        }
    }

    /// Offset both DTS and PTS of a sample for gapless looping.
    /// Returns the original sample unchanged for the first loop (no copy needed).
    /// For subsequent loops, creates a lightweight copy with adjusted timing
    /// (shares the underlying data buffer — only the timing metadata differs).
    private func offsetTimingForLoop(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsOffset > .zero else { return sample }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dur = CMSampleBufferGetDuration(sample)

        var timingInfo = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid,
        )

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjusted,
        )

        return adjusted ?? sample
    }

    /// Reset everything and restart playback from scratch after a decoder error.
    private func recoverFromError() {
        recreatePlayback()
        setClockRate(isPaused ? 0.0 : 1.0)
    }

    // MARK: - Audio

    /// Make this renderer's sound audible (or not). Audio fades in once the picture runs
    /// at normal speed and fades out when deactivated. Thread-safe.
    func setAudio(active: Bool, volume: Float) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            audioVolume = max(0, min(1, volume))
            if active != audioActive {
                audioActive = active
                traceLog("  [audio #\(debugID)] active=\(active) hasTrack=\(audioTrack != nil)")
            }
            startAudioFade()
        }
    }

    /// Cut the sound this instant (unlock, sleep). Safe from any thread; the volume is
    /// zeroed before returning, the rest of the teardown follows on `queue`.
    func silenceAudioNow() {
        audioRenderer.volume = 0
        audioRenderer.isMuted = true
        queue.async { [weak self] in
            guard let self else { return }
            audioActive = false
            audioGain = 0
            stopAudioFade()
            audioRenderer.flush()
        }
    }

    /// Queue decoded audio up to the playback horizon. Must run on `queue`.
    ///
    /// Audio and video come from the same reader, so audio is always read at least as
    /// far as the video that has been enqueued — this keeps the reader's two outputs
    /// balanced. While inaudible, samples are read and dropped; while audible they go
    /// to the audio renderer up to `audioLead` seconds ahead of the clock.
    private func pumpAudio() {
        guard let output = currentAudioOutput else { return }
        if audioRenderer.status == .failed {
            extensionLog("  [audio #\(debugID)] renderer failed: \(audioRenderer.error?.localizedDescription ?? "unknown") → flush")
            audioRenderer.flush()
        }

        let videoHorizon = lastEnqueuedEnd.seconds
        let now = CMTimebaseGetTime(timebase).seconds
        let limit = audioActive
            ? max(videoHorizon, (now.isFinite ? now : 0) + Self.audioLead)
            : videoHorizon

        while true {
            if pendingAudio == nil {
                guard let raw = output.copyNextSampleBuffer() else {
                    currentAudioOutput = nil
                    return
                }
                pendingAudio = prepareAudioSample(raw)
                if pendingAudio == nil { continue }
            }
            guard let sample = pendingAudio else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if pts.isFinite, pts > limit { return }
            if audioActive {
                guard audioRenderer.isReadyForMoreMediaData else { return }
                audioRenderer.enqueue(sample)
            }
            pendingAudio = nil
        }
    }

    /// Cut audio at the clip's video end and move it onto the running timeline.
    /// Returns nil for buffers that lie entirely past the end.
    private func prepareAudioSample(_ raw: CMSampleBuffer) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(raw)
        guard pts.isValid else { return nil }
        var sample = raw
        if clipEnd.isValid {
            guard pts < clipEnd else { return nil }
            let duration = CMSampleBufferGetDuration(raw)
            if duration.isValid, CMTimeAdd(pts, duration) > clipEnd,
               let trimmed = Self.trimAudio(raw, keeping: CMTimeSubtract(clipEnd, pts)) {
                sample = trimmed
            }
        }
        return Self.offsetAllTimings(sample, by: ptsOffset)
    }

    /// First `length` of an LPCM buffer.
    private static func trimAudio(_ sample: CMSampleBuffer, keeping length: CMTime) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0
        else { return nil }
        let total = CMSampleBufferGetNumSamples(sample)
        let keep = min(total, Int((length.seconds * asbd.mSampleRate).rounded(.down)))
        guard keep > 0 else { return nil }
        guard keep < total else { return sample }
        var out: CMSampleBuffer?
        CMSampleBufferCopySampleBufferForRange(
            allocator: nil,
            sampleBuffer: sample,
            sampleRange: CFRange(location: 0, length: keep),
            sampleBufferOut: &out,
        )
        return out
    }

    /// Shift every timing entry (audio buffers carry per-sample timing) by `offset`.
    private static func offsetAllTimings(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer {
        guard offset > .zero else { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sample }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, offset)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &out,
        )
        return out ?? sample
    }

    /// Volume envelope, evaluated at 100 Hz on `queue` while audio is (or was) audible.
    private func startAudioFade() {
        guard audioFadeTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.audioFadeInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.stepAudioFade() }
        audioFadeTimer = timer
        timer.resume()
    }

    private func stopAudioFade() {
        audioFadeTimer?.cancel()
        audioFadeTimer = nil
    }

    private func stepAudioFade() {
        let rate = Double(CMTimebaseGetRate(timebase))
        let audible = audioActive && !isPaused && rate >= Self.audibleRate && audioTrack != nil
        let target: Double = audible ? 1 : 0
        if audioGain < target {
            audioGain = min(target, audioGain + Self.audioFadeInterval / Self.audioFadeInDuration)
        } else if audioGain > target {
            audioGain = max(target, audioGain - Self.audioFadeInterval / Self.audioFadeOutDuration)
        }
        // Equal-power curve sounds linear to the ear.
        audioRenderer.volume = audioVolume * Float(sin(audioGain * .pi / 2))
        audioRenderer.isMuted = audioGain <= 0
        if audioActive { pumpAudio() }

        if !audioActive, audioGain <= 0 {
            // Fully faded out: drop queued sound so a later activation starts clean.
            stopAudioFade()
            audioRenderer.flush()
        }
    }

    // MARK: - Still Frame

    private func generateStillFrame() {
        // DISABLED. This spawned an AVAssetImageGenerator (its own video decoder) on
        // every pause to set stillFrameLayer.contents — but a CALayer.contents CGImage
        // does NOT composite in a remote CAContext (RE-confirmed), so it never showed
        // anything. Meanwhile, when the desktop thrashes idle/default, these generators
        // pile up and compete with the playback reader for the appex's limited video-
        // decoder resources, stalling playback (the ~20s "starvation"). When paused the
        // displayLayer already holds the last frame, so nothing visible is lost.
        traceLog("  [generateStillFrame #\(debugID)] skipped (no-op still; last frame held by displayLayer)")
    }
}
