import AVFoundation
import CoreMedia
import Foundation
import os

/// Audio companion for the video-only sample-buffer renderer.
///
/// WallpaperExtensionKit renders video in WallpaperAgent, but the sample-buffer
/// display layer intentionally has no audio path. This controller opens the same
/// asset only while the native lock-screen presentation is visible and follows
/// the renderer's CMTimebase so sound and picture stay together across looping,
/// sleep/wake and policy transitions.
final class LockScreenAudioController: @unchecked Sendable {
    static let shared = LockScreenAudioController()

    private let queue = DispatchQueue(label: "com.wallpaperstudio.lock-screen-audio", qos: .userInteractive)
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var timer: DispatchSourceTimer?
    private var currentURL: URL?
    private var duration: Double = 0
    private weak var renderer: VideoRenderer?

    private init() {}

    func update(
        shouldPlay: Bool,
        volume: Float,
        sourceURL: URL?,
        duration: Double,
        renderer: VideoRenderer?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard shouldPlay, let sourceURL, duration > 0 else {
                stopLocked()
                return
            }

            self.renderer = renderer
            self.duration = duration

            if player == nil || currentURL != sourceURL {
                stopLocked()
                currentURL = sourceURL
                self.renderer = renderer
                self.duration = duration

                let item = AVPlayerItem(url: sourceURL)
                let newPlayer = AVQueuePlayer()
                newPlayer.preventsDisplaySleepDuringVideoPlayback = false
                newPlayer.isMuted = false
                newPlayer.volume = max(0, min(1, volume))
                player = newPlayer
                looper = AVPlayerLooper(player: newPlayer, templateItem: item)
                synchronizeLocked(force: true)
                newPlayer.play()
                startTimerLocked()
                extensionLog("[LockAudio] Started synchronized lock-screen audio")
            } else {
                player?.isMuted = false
                player?.volume = max(0, min(1, volume))
                synchronizeLocked(force: false)
                player?.play()
            }
        }
    }

    /// Safe from any callback thread. The volume is cut synchronously before the
    /// asynchronous teardown, preventing audio from leaking into the unlocked UI.
    func stopImmediately() {
        if let player {
            player.volume = 0
            player.pause()
        }
        queue.async { [weak self] in self?.stopLocked() }
    }

    private func startTimerLocked() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            self?.synchronizeLocked(force: false)
        }
        self.timer = timer
        timer.resume()
    }

    private func synchronizeLocked(force: Bool) {
        guard let player, duration > 0, let renderer else { return }
        let videoSeconds = renderer.playbackTimeSeconds
        guard videoSeconds.isFinite else { return }
        let expected = videoSeconds.truncatingRemainder(dividingBy: duration)
        let actual = player.currentTime().seconds
        guard actual.isFinite else {
            seekLocked(to: expected)
            return
        }

        let direct = abs(actual - expected)
        let wrapped = max(0, duration - direct)
        let drift = min(direct, wrapped)
        if force || drift > 0.12 {
            seekLocked(to: expected)
        }
    }

    private func seekLocked(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player?.seek(
            to: target,
            toleranceBefore: CMTime(seconds: 0.02, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.02, preferredTimescale: 600)
        )
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        player?.volume = 0
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        currentURL = nil
        duration = 0
        renderer = nil
    }
}
