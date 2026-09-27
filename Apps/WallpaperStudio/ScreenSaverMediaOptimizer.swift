@preconcurrency import AVFoundation
import Foundation
import WallpaperCore

enum ScreenSaverOptimizationError: Error, LocalizedError {
    case missingVideoTrack
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            "The video has no valid video track for the Screen Saver."
        case .exportUnavailable:
            "The optimized Screen Saver copy couldn't be created."
        }
    }
}

/// Produces a hardware-friendly playback proxy while preserving the library master.
struct ScreenSaverMediaOptimizer: Sendable {
    func optimize(
        sourceURL: URL,
        item: MediaItem,
        displayTarget: DisplayTarget,
        displays: [DisplayDescriptor],
        cacheDirectory: URL
    ) async throws -> URL {
        let selectedDisplays: [DisplayDescriptor]
        switch displayTarget {
        case .all:
            selectedDisplays = displays
        case let .display(id):
            selectedDisplays = displays.filter { $0.id == id }
        }
        let needs4K = selectedDisplays.contains {
            max($0.pixelSize.width, $0.pixelSize.height) >= 3_840
        }
        let tier = needs4K ? "2160" : "1080"
        let checksumPrefix = String(item.checksum.prefix(16))
        let destinationDirectory = cacheDirectory
            .appendingPathComponent("ScreenSaverPlayback", isDirectory: true)
        let destination = destinationDirectory
            .appendingPathComponent("\(item.id.uuidString)-\(checksumPrefix)-\(tier).mov")
        if Self.isNonemptyFile(destination) { return destination }

        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ScreenSaverOptimizationError.missingVideoTrack
        }
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let presets = needs4K
            ? [AVAssetExportPresetHEVC3840x2160, AVAssetExportPreset3840x2160]
            : [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1920x1080]

        for preset in presets {
            try Task.checkCancellation()
            guard await AVAssetExportSession.compatibility(
                ofExportPreset: preset,
                with: asset,
                outputFileType: .mov
            ), let exporter = AVAssetExportSession(asset: asset, presetName: preset)
            else { continue }

            let temporary = destinationDirectory.appendingPathComponent(".\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: temporary)
            exporter.shouldOptimizeForNetworkUse = false
            if nominalFrameRate > 60 {
                let composition = AVMutableVideoComposition(propertiesOf: asset)
                composition.frameDuration = CMTime(value: 1, timescale: 60)
                exporter.videoComposition = composition
            }
            do {
                try await exporter.export(to: temporary, as: .mov)
                guard Self.isNonemptyFile(temporary) else {
                    try? FileManager.default.removeItem(at: temporary)
                    continue
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                return destination
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: temporary)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        throw ScreenSaverOptimizationError.exportUnavailable
    }

    private static func isNonemptyFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}
