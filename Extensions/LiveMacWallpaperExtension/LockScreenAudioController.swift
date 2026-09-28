import AVFoundation
import CoreMedia
import Foundation
import os

/// Audio companion for the video-only sample-buffer renderer.
///
/// WallpaperExtensionKit renders video in WallpaperAgent, but the sample-buffer
/// display layer has no audio path. This controller opens the same clip in an
/// audio-only player while the native lock-screen presentation is visible and keeps
/// it aligned with the picture.
///
/// Why the previous version played "in waves": it re-seeked the player whenever it
/// was more than 120 ms away from the video, checked four times a second, and
/// compared against `timebase % libraryDuration`. The library duration never matched
/// the loop length the renderer actually uses, and while the video clock eased from
/// 0 → 1 on lock the audio ran at full speed, so the drift threshold was crossed
/// continuously and every correction was an audible seek (a dropout, then a burst).
///
/// Now:
/// * the clip position comes from the renderer's loop clock (exact loop starts, not a
///   modulo of a guessed duration);
/// * audio waits, silent, while the video clock is paused or ramping and starts once
///   the picture runs at normal speed;
/// * a hard re-sync (seek) only happens on start, on a new clip or after a real jump,
///   and always behind a short fade so it is inaudible;
/// * everyday drift is absorbed by trimming the playback rate by at most ±3 %, with
///   pitch preserved, so the sound never stops to catch up.
final class LockScreenAudioController: @unchecked Sendable {
    static let shared = LockScreenAudioController()

    // MARK: Tuning

    private enum Tuning {
        static let tickInterval: TimeInterval = 1.0 / 30.0
        /// Video must be at (near) normal speed before audio joins in.
        static let runningRate: Double = 0.97
        /// Beyond this the audio is re-seeked (behind a fade) instead of trimmed.
        static let hardResyncThreshold: Double = 0.35
        /// Below this the clocks are treated as aligned.
        static let deadband: Double = 0.012
        /// Rate correction per second of drift, and its ceiling.
        static let trimGain: Double = 0.45
        static let maxTrim: Double = 0.03
        static let trimUpdateInterval: TimeInterval = 0.25
        /// Minimum spacing between two hard re-syncs.
        static let resyncCooldown: TimeInterval = 1.5
        static let fadeIn: TimeInterval = 0.45
        static let fadeOut: TimeInterval = 0.12
        static let driftSmoothing: Double = 0.15
    }

    private enum Phase: Equatable {
        /// Player paused, waiting for a running video clock.
        case waiting
        /// Fading out before a seek.
        case preparingSeek
        /// Seek issued; `token` identifies it so stale completions are ignored.
        case seeking(token: Int)
        /// In sync, rate-trimmed playback.
        case playing
    }

    private let queue = DispatchQueue(label: "com.livemacwallpaper.lock-screen-audio", qos: .userInteractive)

    // Everything below is confined to `queue`, except `livePlayer` (see stopImmediately).
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var timer: DispatchSourceTimer?
    private var currentURL: URL?
    private weak var renderer: VideoRenderer?
    private var wantsPlayback = false
    private var targetVolume: Float = 1
    private var phase: Phase = .waiting
    private var seekToken = 0
    private var lastGeneration: Int?
    private var gain: Double = 0
    private var gainTarget: Double = 0
    private var smoothedDrift: Double = 0
    private var largeDriftTicks = 0
    private var appliedRate: Float = 0
    private var lastTrimUpdate: TimeInterval = 0
    private var lastResync: TimeInterval = -.infinity
    /// Measured time between issuing a seek and audio actually playing.
    private var seekLatency: Double = 0.06

    private let liveLock = NSLock()
    private var livePlayer: AVQueuePlayer?

    private init() {}

    // MARK: Public API

    /// Idempotent: called on every policy change. Only records what should happen;
    /// the clock loop does the work, so frequent calls never cause audible seeks.
    func update(
        shouldPlay: Bool,
        volume: Float,
        sourceURL: URL?,
        renderer: VideoRenderer?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            targetVolume = max(0, min(1, volume))

            guard shouldPlay, let sourceURL, let renderer else {
                wantsPlayback = false
                if player == nil {
                    stopLocked()
                } else {
                    gainTarget = 0
                    ensureTimerLocked()
                }
                return
            }

            wantsPlayback = true
            if self.renderer !== renderer {
                self.renderer = renderer
                lastGeneration = nil
                requestResyncLocked()
            }
            if player == nil || currentURL != sourceURL {
                openLocked(sourceURL)
            }
            ensureTimerLocked()
        }
    }

    /// Safe from any callback thread. The volume is cut synchronously before the
    /// asynchronous teardown, preventing audio from leaking into the unlocked UI.
    func stopImmediately() {
        liveLock.lock()
        let live = livePlayer
        liveLock.unlock()
        if let live {
            live.volume = 0
            live.pause()
        }
        queue.async { [weak self] in
            self?.wantsPlayback = false
            self?.stopLocked()
        }
    }

    // MARK: Player lifecycle

    private func openLocked(_ url: URL) {
        teardownPlayerLocked()
        currentURL = url

        let item = AVPlayerItem(url: url)
        // Rate trimming must not change pitch.
        item.audioTimePitchAlgorithm = .timeDomain
        let newPlayer = AVQueuePlayer()
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        newPlayer.isMuted = false
        newPlayer.volume = 0
        let newLooper = AVPlayerLooper(player: newPlayer, templateItem: item)
        for looping in newLooper.loopingPlayerItems {
            looping.audioTimePitchAlgorithm = .timeDomain
        }

        player = newPlayer
        looper = newLooper
        liveLock.lock()
        livePlayer = newPlayer
        liveLock.unlock()

        gain = 0
        gainTarget = 0
        appliedRate = 0
        phase = .waiting
        lastGeneration = nil
        smoothedDrift = 0
        extensionLog("[LockAudio] Opened \(url.lastPathComponent)")
    }

    private func teardownPlayerLocked() {
        seekToken &+= 1
        player?.volume = 0
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        liveLock.lock()
        livePlayer = nil
        liveLock.unlock()
        currentURL = nil
        appliedRate = 0
        gain = 0
        phase = .waiting
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        teardownPlayerLocked()
        renderer = nil
        lastGeneration = nil
    }

    private func ensureTimerLocked() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Tuning.tickInterval,
            repeating: Tuning.tickInterval,
            leeway: .milliseconds(4)
        )
        timer.setEventHandler { [weak self] in self?.tickLocked() }
        self.timer = timer
        timer.resume()
    }

    // MARK: Clock loop

    private func tickLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { applyGainLocked() }

        guard let player else {
            if !wantsPlayback { stopLocked() }
            return
        }

        // Leaving the lock screen: fade out, then tear down.
        guard wantsPlayback else {
            gainTarget = 0
            if gain <= 0.001 { stopLocked() }
            return
        }

        guard let sample = renderer?.clockSample() else {
            holdLocked(player)
            return
        }

        // Video paused or easing in/out (lock ramp, deep pause): stay silent and wait.
        guard sample.rate >= Tuning.runningRate else {
            holdLocked(player)
            return
        }

        if lastGeneration != sample.generation {
            lastGeneration = sample.generation
            requestResyncLocked()
        }

        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let period = item.duration.seconds
        guard period.isFinite, period > 0.1 else { return }

        switch phase {
        case .waiting, .preparingSeek:
            gainTarget = 0
            if gain <= 0.001 {
                beginSeekLocked(player: player, sample: sample, period: period, now: now)
            } else {
                phase = .preparingSeek
            }

        case .seeking:
            return

        case .playing:
            let expected = sample.loopPosition.truncatingRemainder(dividingBy: period)
            let actual = player.currentTime().seconds
            guard actual.isFinite else {
                requestResyncLocked()
                return
            }
            let drift = Self.circularDifference(actual - expected, period: period)

            // A single outlier (e.g. the looper handing over to the next item) is not
            // a jump; require it to persist for a few ticks.
            largeDriftTicks = abs(drift) > Tuning.hardResyncThreshold ? largeDriftTicks + 1 : 0
            if largeDriftTicks >= 3, now - lastResync > Tuning.resyncCooldown {
                largeDriftTicks = 0
                extensionLog("[LockAudio] Drift \(String(format: "%.3f", drift))s → re-sync")
                requestResyncLocked()
                return
            }

            guard largeDriftTicks == 0 else { return }
            smoothedDrift += (drift - smoothedDrift) * Tuning.driftSmoothing
            gainTarget = 1

            guard now - lastTrimUpdate >= Tuning.trimUpdateInterval else { return }
            lastTrimUpdate = now
            // Audio ahead (positive drift) → play slightly slower, and vice versa.
            let correction = abs(smoothedDrift) < Tuning.deadband
                ? 0
                : max(-Tuning.maxTrim, min(Tuning.maxTrim, smoothedDrift * Tuning.trimGain))
            setRateLocked(player, Float(1 - correction))
        }
    }

    private func holdLocked(_ player: AVQueuePlayer) {
        gainTarget = 0
        if gain <= 0.001, appliedRate != 0 {
            setRateLocked(player, 0)
        }
        if phase == .playing || phase == .preparingSeek {
            phase = .waiting
        }
    }

    private func requestResyncLocked() {
        if case .seeking = phase { seekToken &+= 1 }
        phase = gain > 0.001 ? .preparingSeek : .waiting
        gainTarget = 0
    }

    private func beginSeekLocked(player: AVQueuePlayer, sample: VideoRenderer.ClockSample, period: Double, now: TimeInterval) {
        setRateLocked(player, 0)
        seekToken &+= 1
        let token = seekToken
        phase = .seeking(token: token)
        lastResync = now

        // Aim where the picture will be once the seek has landed.
        let target = (sample.loopPosition + seekLatency).truncatingRemainder(dividingBy: period)
        let issuedAt = now
        player.seek(
            to: CMTime(seconds: max(0, target), preferredTimescale: 48_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            self?.queue.async {
                guard let self, case let .seeking(current) = self.phase, current == token else { return }
                guard finished, let player = self.player, self.wantsPlayback else {
                    self.phase = .waiting
                    return
                }
                let measured = ProcessInfo.processInfo.systemUptime - issuedAt
                self.seekLatency = max(0.01, min(0.3, self.seekLatency * 0.6 + measured * 0.4))
                self.smoothedDrift = 0
                self.largeDriftTicks = 0
                self.lastTrimUpdate = 0
                self.phase = .playing
                self.setRateLocked(player, 1)
                self.gainTarget = 1
            }
        }
    }

    private func setRateLocked(_ player: AVQueuePlayer, _ rate: Float) {
        guard abs(rate - appliedRate) > 0.0015 else { return }
        appliedRate = rate
        if rate == 0 {
            player.pause()
        } else {
            player.playImmediately(atRate: rate)
        }
    }

    private func applyGainLocked() {
        let step = gainTarget > gain
            ? Tuning.tickInterval / Tuning.fadeIn
            : Tuning.tickInterval / Tuning.fadeOut
        if gain < gainTarget {
            gain = min(gainTarget, gain + step)
        } else if gain > gainTarget {
            gain = max(gainTarget, gain - step)
        }
        // Equal-power curve sounds like a linear fade to the ear.
        let volume = targetVolume * Float(sin(gain * .pi / 2))
        if let player, abs(player.volume - volume) > 0.0005 {
            player.volume = volume
        }
    }

    /// Signed difference folded into (-period/2, period/2], so a wrap at the loop
    /// point is not mistaken for a full-clip jump.
    static func circularDifference(_ value: Double, period: Double) -> Double {
        guard period > 0 else { return value }
        var d = value.truncatingRemainder(dividingBy: period)
        if d > period / 2 { d -= period }
        if d <= -period / 2 { d += period }
        return d
    }
}
