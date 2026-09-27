import Foundation
import Testing
@testable import WallpaperCore

@Suite("Runtime configuration")
struct RuntimeConfigurationStoreTests {
    @Test("Persists a valid independent destination profile")
    func persistsProfile() async throws {
        let temporary = try TemporaryDirectory()
        let mediaID = UUID()
        let profile = WallpaperProfile(
            name: "Independent",
            desktop: DestinationConfiguration(selection: .media(mediaID)),
            screenSaver: DestinationConfiguration(selection: .off),
            lockScreen: DestinationConfiguration(selection: .media(mediaID))
        )
        let store = RuntimeConfigurationStore(directories: AppDirectories(root: temporary.url))

        try await store.save(profile: profile, availableMediaIDs: [mediaID])
        let loaded = try await store.load()
        #expect(loaded?.activeProfile == profile)
    }

    @Test("Migrates a schema 1 runtime configuration in place")
    func migratesSchemaOne() async throws {
        let temporary = try TemporaryDirectory()
        let directories = AppDirectories(root: temporary.url)
        try directories.prepare()
        let profile = WallpaperProfile(name: "Legacy")
        let encoded = try AtomicJSON.encoder.encode(RuntimeConfiguration(activeProfile: profile))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: object).write(to: directories.activeConfiguration)

        let store = RuntimeConfigurationStore(directories: directories)
        let migrated = try await store.load()
        #expect(migrated?.schemaVersion == RuntimeConfiguration.currentSchemaVersion)

        let persisted = try AtomicJSON.decoder.decode(
            RuntimeConfiguration.self,
            from: Data(contentsOf: directories.activeConfiguration)
        )
        #expect(persisted.schemaVersion == RuntimeConfiguration.currentSchemaVersion)
    }
}
