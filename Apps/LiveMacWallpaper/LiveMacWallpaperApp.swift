import SwiftUI

@main
struct LiveMacWallpaperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, idealWidth: 1360, minHeight: 540, idealHeight: 860)
                .task { await model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        // The window can't be made smaller than the layout's minimum.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Files…") {
                    model.chooseFiles()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Import from YouTube…") {
                    model.isYouTubeSheetPresented = true
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) {
                        model.closeDetail()
                        model.selectedSection = section
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            CommandMenu("Wallpaper") {
                Button("Lock with Live Mac Wallpaper") {
                    Task { await model.lockNowWithLiveMacWallpaper() }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.isApplying)

                Divider()

                Button(model.desktopEngine.isPaused ? "Resume Playback" : "Pause") {
                    model.toggleDesktopPlayback()
                }
                .disabled(!model.desktopEngine.isRunning)

                Divider()

                Button("Apply Profile") {
                    Task { await model.applyProfileAndInstallLockScreen() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isApplying)
            }
        }

        Settings {
            SettingsView(isStandaloneWindow: true)
                .environmentObject(model)
                .measuresLayout()
                .frame(minWidth: 560, idealWidth: 820, minHeight: 480, idealHeight: 680)
        }
    }
}
