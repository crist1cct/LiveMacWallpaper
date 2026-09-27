import Foundation
import Testing
@testable import WallpaperCore

@Suite("Display targeting")
struct DisplayTargetTests {
    private let displays = [
        DisplayDescriptor(
            id: "main-display",
            directDisplayID: 1,
            name: "Built-in Display",
            pixelSize: PixelSize(width: 3_024, height: 1_964),
            isMain: true
        ),
        DisplayDescriptor(
            id: "external-display",
            directDisplayID: 2,
            name: "Studio Display",
            pixelSize: PixelSize(width: 5_120, height: 2_880),
            isMain: false
        )
    ]

    @Test("All displays resolves to every stable display ID")
    func resolvesAllDisplays() throws {
        #expect(try DisplayTarget.all.resolvedIDs(in: displays) == ["main-display", "external-display"])
    }

    @Test("One display never leaks onto another display")
    func resolvesExactlyOneDisplay() throws {
        #expect(try DisplayTarget.display("external-display").resolvedIDs(in: displays) == ["external-display"])
    }

    @Test("A disconnected selected display is rejected")
    func rejectsDisconnectedDisplay() {
        #expect(throws: DisplayTargetError.displayUnavailable("missing-display")) {
            try DisplayTarget.display("missing-display").resolvedIDs(in: displays)
        }
    }

    @Test("The active screen catalog round-trips stable identifiers") @MainActor
    func liveCatalogRoundTrip() throws {
        let connected = DisplayCatalog.connectedDisplays
        #expect(!connected.isEmpty)
        #expect(try DisplayCatalog.resolvedDisplayIDs(for: .all) == Set(connected.map(\.id)))
        for display in connected {
            let matched = try DisplayCatalog.screens(for: .display(display.id))
            #expect(matched.count == 1)
            #expect(DisplayCatalog.persistentID(for: matched[0]) == display.id)
        }
    }
}
