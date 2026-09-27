import SwiftUI

@main
struct WallpaperStudioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 680)
                .task { await model.start() }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Importă fișiere…") {
                    model.chooseFiles()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Importă din YouTube…") {
                    model.isYouTubeSheetPresented = true
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandMenu("Wallpaper") {
                Button("Blochează cu Wallpaper Studio") {
                    Task { await model.lockNowWithWallpaperStudio() }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.isApplying)

                Divider()

                Button(model.desktopEngine.isPaused ? "Reia redarea" : "Pauză") {
                    model.toggleDesktopPlayback()
                }
                .disabled(!model.desktopEngine.isRunning)

                Divider()

                Button("Aplică profilul") {
                    Task { await model.applyProfileAndInstallLockScreen() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isApplying)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 840, height: 650)
        }
    }
}
