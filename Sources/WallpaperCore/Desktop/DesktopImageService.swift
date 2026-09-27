import AppKit
import Foundation

public struct DesktopImageApplicationResult: Sendable, Equatable {
    public let displayIDs: Set<String>

    public init(displayIDs: Set<String>) {
        self.displayIDs = displayIDs
    }

    public var displayCount: Int { displayIDs.count }
}

public enum DesktopImageApplicationError: Error, Equatable, LocalizedError {
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed:
            "macOS nu a confirmat imaginea pe unul dintre ecranele selectate."
        }
    }
}

@MainActor
public final class DesktopImageService {
    public init() {}

    @discardableResult
    public func apply(
        imageURL: URL,
        scaling: ContentScaling,
        displayTarget: DisplayTarget = .all
    ) throws -> DesktopImageApplicationResult {
        let screens = try DisplayCatalog.screens(for: displayTarget)
        let options = desktopOptions(for: scaling)
        var appliedIDs = Set<String>()
        for screen in screens {
            try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: options)
            guard NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == imageURL.standardizedFileURL,
                  let displayID = DisplayCatalog.persistentID(for: screen)
            else {
                throw DesktopImageApplicationError.verificationFailed(
                    DisplayCatalog.persistentID(for: screen) ?? "unknown"
                )
            }
            appliedIDs.insert(displayID)
        }
        return DesktopImageApplicationResult(displayIDs: appliedIDs)
    }

    private func desktopOptions(
        for scaling: ContentScaling
    ) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        switch scaling {
        case .fill:
            [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true
            ]
        case .fit:
            [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: false
            ]
        case .stretch:
            [
                .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
                .allowClipping: false
            ]
        }
    }
}
