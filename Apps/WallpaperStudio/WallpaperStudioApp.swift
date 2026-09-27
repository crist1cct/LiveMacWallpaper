import SwiftUI

@main
struct WallpaperStudioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 700)
                .task { await model.start() }
        }
        .windowStyle(.hiddenTitleBar)
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
                Button("Lock with Wallpaper Studio") {
                    Task { await model.lockNowWithWallpaperStudio() }
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
                .frame(width: 820, height: 680)
        }
    }
}
