import Foundation
import Testing
@testable import WallpaperCore

@Suite("Wallpaper profile validation")
struct ProfileValidatorTests {
    @Test("Default profile resolves without a cycle")
    func defaultProfileIsValid() throws {
        let profile = WallpaperProfile(name: "Default")
        try ProfileValidator().validate(profile, availableMediaIDs: [])
    }

    @Test("Follow cycles are rejected")
    func rejectsFollowCycle() {
        var profile = WallpaperProfile(name: "Cycle")
        profile.desktop.selection = .follow(.lockScreen)
        profile.lockScreen.selection = .follow(.desktop)

        #expect(throws: ProfileValidationError.self) {
            try ProfileValidator().validate(profile, availableMediaIDs: [])
        }
    }

    @Test("Missing media references are rejected")
    func rejectsMissingMedia() {
        let missingID = UUID()
        let profile = WallpaperProfile(
            name: "Missing",
            desktop: DestinationConfiguration(selection: .media(missingID))
        )

        #expect(throws: ProfileValidationError.missingMedia(missingID)) {
            try ProfileValidator().validate(profile, availableMediaIDs: [])
        }
    }

    @Test("Older profiles receive safe defaults for new display settings")
    func decodesOlderDestinationConfiguration() throws {
        let json = #"{"selection":{"systemDefault":{}},"scaling":"fit","muteVideo":true}"#
        let decoded = try JSONDecoder().decode(
            DestinationConfiguration.self,
            from: Data(json.utf8)
        )

        #expect(decoded.selection == .systemDefault)
        #expect(decoded.scaling == .fit)
        #expect(decoded.targetDisplayIDs == nil)
        #expect(decoded.displayTarget == .all)
        #expect(decoded.pauseInLowPowerMode)
    }

    @Test("Schema 1 display IDs migrate to one explicit display")
    func migratesLegacyDisplayTarget() throws {
        let json = #"{"selection":{"systemDefault":{}},"targetDisplayIDs":["display-2"]}"#
        let decoded = try JSONDecoder().decode(
            DestinationConfiguration.self,
            from: Data(json.utf8)
        )

        #expect(decoded.displayTarget == .display("display-2"))
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["displayTarget"] != nil)
        #expect(object["targetDisplayIDs"] == nil)
    }
}
