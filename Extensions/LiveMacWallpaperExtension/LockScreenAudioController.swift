import Foundation
import os

/// Decides which renderer's sound is audible on the Lock Screen.
///
/// Playback itself is native: every `VideoRenderer` decodes its clip's audio from the
/// same reader as the picture and plays it through an `AVSampleBufferAudioRenderer`
/// attached to the same `AVSampleBufferRenderSynchronizer` as the video. Picture and
/// sound therefore run on one clock and never need re-synchronizing. This controller
/// only picks one renderer (one display) to be audible, sets its volume, and cuts the
/// sound instantly on unlock or sleep.
final class LockScreenAudioController: @unchecked Sendable {
    static let shared = LockScreenAudioController()

    private let lock = OSAllocatedUnfairLock<WeakRenderer>(initialState: WeakRenderer())

    private struct WeakRenderer: @unchecked Sendable {
        weak var renderer: VideoRenderer?
    }

    private init() {}

    /// Idempotent; called on every policy change.
    func update(shouldPlay: Bool, volume: Float, renderer: VideoRenderer?) {
        let previous = lock.withLock { state -> VideoRenderer? in
            let old = state.renderer
            state.renderer = shouldPlay ? renderer : nil
            return old
        }
        if let previous, previous !== renderer || !shouldPlay {
            previous.setAudio(active: false, volume: volume)
        }
        guard shouldPlay, let renderer else { return }
        renderer.setAudio(active: true, volume: volume)
    }

    /// Safe from any callback thread: the volume is zero before this returns, so no
    /// sound can leak into the unlocked session.
    func stopImmediately() {
        let current = lock.withLock { state -> VideoRenderer? in
            let old = state.renderer
            state.renderer = nil
            return old
        }
        current?.silenceAudioNow()
        // Belt and braces: no display may keep sound after unlock.
        WallpaperState.shared.forEachRenderer { renderer in
            if renderer !== current { renderer.silenceAudioNow() }
        }
    }
}
