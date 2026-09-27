import SwiftUI
import WallpaperCore

/// Settings: one centered column of large, plainly worded rows
/// grouped on glass. Used both as a tab in the main window and in the Settings scene.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var isStandaloneWindow = false

    init(isStandaloneWindow: Bool = false) {
        self.isStandaloneWindow = isStandaloneWindow
    }

    var body: some View {
        ZStack {
            TV.canvas.ignoresSafeArea()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 30) {
                    Text("Settings")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)

                    SettingsGroup(title: "Playback") {
                        SettingsRow(symbol: "power", title: "Launch at Login", detail: "Keeps the Desktop wallpaper running after login, even when the app is closed.") {
                            Toggle("", isOn: Binding(
                                get: { model.isLoginItemEnabled },
                                set: { model.setLoginItemEnabled($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.green)
                        }
                        SettingsDivider()
                        SettingsRow(
                            symbol: model.desktopEngine.isPaused ? "play.fill" : "pause.fill",
                            title: "Desktop Playback",
                            detail: model.desktopEngine.isRunning
                                ? (model.desktopEngine.isPaused ? "Paused" : "Playing")
                                : "No video on the Desktop"
                        ) {
                            Button(model.desktopEngine.isPaused ? "Resume" : "Pause") {
                                model.toggleDesktopPlayback()
                            }
                            .buttonStyle(TVGlassButtonStyle(height: 34))
                            .disabled(!model.desktopEngine.isRunning)
                        }
                    }

                    SettingsGroup(title: "Lock Screen") {
                        SettingsRow(
                            symbol: "lock.fill",
                            title: "Status",
                            detail: model.loginWallpaperStatus.isReady
                                ? "Ready. Your wallpaper appears when you lock the screen."
                                : "Choose a video for the Lock Screen from the Library."
                        ) {
                            StatusDot(isOn: model.loginWallpaperStatus.isReady)
                        }
                        SettingsDivider()
                        SettingsRow(symbol: "lock.display", title: "Test Now", detail: "Lock the screen to see the result (⇧⌘L).") {
                            Button("Lock") {
                                Task { await model.lockNowWithWallpaperStudio() }
                            }
                            .buttonStyle(TVGlassButtonStyle(height: 34))
                            .disabled(model.isApplying)
                        }
                    }

                    SettingsGroup(title: "Screen Saver") {
                        SettingsRow(symbol: "sparkles.tv", title: "Component", detail: screenSaverStatus) {
                            HStack(spacing: 8) {
                                Button(model.isScreenSaverInstalled ? "Update" : "Install") {
                                    model.installScreenSaver()
                                }
                                .buttonStyle(TVGlassButtonStyle(height: 34))
                                Button("macOS Settings") {
                                    model.integrations.openScreenSaverSettings()
                                }
                                .buttonStyle(TVGlassButtonStyle(height: 34))
                            }
                        }
                    }

                    SettingsGroup(title: "Import") {
                        SettingsRow(symbol: "square.and.arrow.down", title: "Import Quality", detail: qualityDetail) {
                            Picker("", selection: $model.importQuality) {
                                Text("Efficient").tag(MediaQuality.efficient)
                                Text("Native").tag(MediaQuality.native)
                                Text("Original").tag(MediaQuality.original)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 250)
                        }
                        SettingsDivider()
                        SettingsRow(symbol: "play.rectangle.fill", title: "YouTube", detail: youtubeStatus) {
                            Button("Import…") { model.isYouTubeSheetPresented = true }
                                .buttonStyle(TVGlassButtonStyle(height: 34))
                                .disabled(!isYouTubeReady)
                        }
                    }

                    SettingsGroup(title: "Storage") {
                        SettingsRow(symbol: "internaldrive", title: "Library", detail: model.backendLocationLabel) {
                            Button("Show in Finder") { model.revealLibraryInFinder() }
                                .buttonStyle(TVGlassButtonStyle(height: 34))
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, TV.pageInset)
                .padding(.top, isStandaloneWindow ? 36 : 96)
                .padding(.bottom, 60)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .ignoresSafeArea(edges: isStandaloneWindow ? [] : .top)
        }
        .preferredColorScheme(.dark)
        .tint(.white)
    }

    private var isYouTubeReady: Bool {
        if case .ready = model.youtubeHelperStatus { return true }
        return false
    }

    private var qualityDetail: String {
        switch model.importQuality {
        case .efficient: "Smaller files, up to 1080p."
        case .native: "Balanced, up to 4K. Recommended."
        case .original: "No resizing, maximum fidelity."
        }
    }

    private var youtubeStatus: String {
        switch model.youtubeHelperStatus {
        case .unavailable: "Not included in this build."
        case let .ready(version): "Ready · \(version) · highest available quality"
        case let .failed(reason): "Needs attention: \(reason)"
        }
    }

    private var screenSaverStatus: String {
        guard model.isScreenSaverInstalled else { return "Not installed" }
        guard model.integrations.isScreenSaverCurrent else { return "Update available" }
        return model.integrations.isScreenSaverSelected
            ? "Installed and active · always muted"
            : "Installed · choose a Screen Saver wallpaper"
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(TV.tertiaryText)
                .padding(.leading, 6)
            VStack(spacing: 0) { content }
                .padding(.vertical, 6)
                .tvGlass(in: RoundedRectangle(cornerRadius: TV.panelRadius, style: .continuous))
        }
    }
}

private struct SettingsRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(TV.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            accessory
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(TV.hairline)
            .frame(height: 1)
            .padding(.leading, 70)
    }
}

private struct StatusDot: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(isOn ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(isOn ? "Active" : "Not configured")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(TV.secondaryText)
        }
    }
}
