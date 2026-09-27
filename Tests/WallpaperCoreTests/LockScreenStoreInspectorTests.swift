import Foundation
import Testing
@testable import WallpaperCore

@Suite("Lock screen store inspector")
struct LockScreenStoreInspectorTests {
    @Test("Recognizes separate Desktop and Idle nodes on a known macOS version")
    func recognizesKnownStructure() throws {
        let temporary = try TemporaryDirectory()
        let storeURL = temporary.url.appendingPathComponent("Index.plist")
        let plist: [String: Any] = [
            "AllSpacesAndDisplays": [
                "Desktop": ["Content": [:]],
                "Idle": ["Content": [:]]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: storeURL)

        let report = LockScreenStoreInspector().inspect(
            storeURL: storeURL,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        #expect(report.desktopAndIdlePairCount == 1)
        #expect(report.canAttemptExperimentalIntegration)
    }

    @Test("Unknown macOS versions fail closed")
    func unknownVersionFailsClosed() throws {
        let temporary = try TemporaryDirectory()
        let storeURL = temporary.url.appendingPathComponent("Index.plist")
        let plist: [String: Any] = ["Desktop": [:], "Idle": [:]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: storeURL)

        let report = LockScreenStoreInspector().inspect(
            storeURL: storeURL,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )
        #expect(!report.canAttemptExperimentalIntegration)
        #expect(!report.reasons.isEmpty)
    }
}

