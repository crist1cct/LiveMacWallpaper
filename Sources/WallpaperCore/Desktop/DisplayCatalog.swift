import AppKit
import CoreFoundation
import CoreGraphics
import Foundation

public struct DisplayDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let directDisplayID: UInt32
    public let name: String
    public let pixelSize: PixelSize
    public let isMain: Bool

    public init(
        id: String,
        directDisplayID: UInt32,
        name: String,
        pixelSize: PixelSize,
        isMain: Bool
    ) {
        self.id = id
        self.directDisplayID = directDisplayID
        self.name = name
        self.pixelSize = pixelSize
        self.isMain = isMain
    }
}

public enum DisplayTargetError: Error, Equatable, LocalizedError {
    case noDisplaysConnected
    case displayUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplaysConnected:
            "Nu a fost detectat niciun ecran conectat."
        case .displayUnavailable:
            "Ecranul selectat nu mai este conectat. Reîncarcă lista și alege un ecran disponibil."
        }
    }
}

public extension DisplayTarget {
    func resolvedIDs(in displays: [DisplayDescriptor]) throws -> Set<String> {
        guard !displays.isEmpty else { throw DisplayTargetError.noDisplaysConnected }
        switch self {
        case .all:
            return Set(displays.map(\.id))
        case let .display(id):
            guard displays.contains(where: { $0.id == id }) else {
                throw DisplayTargetError.displayUnavailable(id)
            }
            return [id]
        }
    }
}

@MainActor
public enum DisplayCatalog {
    public static var connectedDisplays: [DisplayDescriptor] {
        let primaryDisplayID = NSScreen.screens.first.flatMap { directDisplayID(for: $0) }
        return NSScreen.screens.compactMap { screen -> DisplayDescriptor? in
            guard let directDisplayID = directDisplayID(for: screen) else { return nil }
            return DisplayDescriptor(
                id: persistentID(for: directDisplayID),
                directDisplayID: directDisplayID,
                name: screen.localizedName,
                pixelSize: PixelSize(
                    width: Int(CGDisplayPixelsWide(directDisplayID)),
                    height: Int(CGDisplayPixelsHigh(directDisplayID))
                ),
                isMain: directDisplayID == primaryDisplayID
            )
        }
        .sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func screens(matching displayIDs: Set<String>?) -> [NSScreen] {
        guard let displayIDs else { return NSScreen.screens }
        return NSScreen.screens.filter { screen in
            persistentID(for: screen).map(displayIDs.contains) ?? false
        }
    }

    public static func screens(for target: DisplayTarget) throws -> [NSScreen] {
        let available = NSScreen.screens
        guard !available.isEmpty else { throw DisplayTargetError.noDisplaysConnected }
        switch target {
        case .all:
            return available
        case let .display(id):
            let matches = available.filter { persistentID(for: $0) == id }
            guard !matches.isEmpty else { throw DisplayTargetError.displayUnavailable(id) }
            return matches
        }
    }

    public static func resolvedDisplayIDs(for target: DisplayTarget) throws -> Set<String> {
        try target.resolvedIDs(in: connectedDisplays)
    }

    public static func persistentID(for screen: NSScreen) -> String? {
        directDisplayID(for: screen).map(persistentID(for:))
    }

    public static func directDisplayID(for screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private static func persistentID(for directDisplayID: UInt32) -> String {
        guard let value = CGDisplayCreateUUIDFromDisplayID(directDisplayID)?.takeRetainedValue()
        else {
            return String(directDisplayID)
        }
        return CFUUIDCreateString(nil, value) as String
    }
}
