import SwiftUI
import WallpaperCore

/// Settings in the tvOS manner: one centered column of large, plainly worded rows
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
                    Text("Setări")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)

                    SettingsGroup(title: "Redare") {
                        SettingsRow(symbol: "power", title: "Pornește cu Mac-ul", detail: "Wallpaperul de pe Desktop rămâne activ după autentificare, chiar și cu aplicația închisă.") {
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
                            title: "Redarea pe Desktop",
                            detail: model.desktopEngine.isRunning
                                ? (model.desktopEngine.isPaused ? "În pauză" : "Rulează")
                                : "Niciun video pe Desktop"
                        ) {
                            Button(model.desktopEngine.isPaused ? "Reia" : "Pauză") {
                                model.toggleDesktopPlayback()
                            }
                            .buttonStyle(TVGlassButtonStyle(height: 34))
                            .disabled(!model.desktopEngine.isRunning)
                        }
                    }

                    SettingsGroup(title: "Lock Screen") {
                        SettingsRow(
                            symbol: "lock.fill",
                            title: "Stare",
                            detail: model.loginWallpaperStatus.isReady
                                ? "Pregătit. Wallpaperul tău apare când blochezi ecranul."
                                : "Alege un video pentru Lock Screen din Bibliotecă."
                        ) {
                            StatusDot(isOn: model.loginWallpaperStatus.isReady)
                        }
                        SettingsDivider()
                        SettingsRow(symbol: "lock.display", title: "Testează acum", detail: "Blochează ecranul ca să vezi rezultatul (⇧⌘L).") {
                            Button("Blochează") {
                                Task { await model.lockNowWithWallpaperStudio() }
                            }
                            .buttonStyle(TVGlassButtonStyle(height: 34))
                            .disabled(model.isApplying)
                        }
                    }

                    SettingsGroup(title: "Screen Saver") {
                        SettingsRow(symbol: "sparkles.tv", title: "Componentă", detail: screenSaverStatus) {
                            HStack(spacing: 8) {
                                Button(model.isScreenSaverInstalled ? "Actualizează" : "Instalează") {
                                    model.installScreenSaver()
                                }
                                .buttonStyle(TVGlassButtonStyle(height: 34))
                                Button("Setări macOS") {
                                    model.integrations.openScreenSaverSettings()
                                }
                                .buttonStyle(TVGlassButtonStyle(height: 34))
                            }
                        }
                    }

                    SettingsGroup(title: "Import") {
                        SettingsRow(symbol: "square.and.arrow.down", title: "Calitate la import", detail: qualityDetail) {
                            Picker("", selection: $model.importQuality) {
                                Text("Eficient").tag(MediaQuality.efficient)
                                Text("Nativ").tag(MediaQuality.native)
                                Text("Original").tag(MediaQuality.original)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 250)
                        }
                        SettingsDivider()
                        SettingsRow(symbol: "play.rectangle.fill", title: "YouTube", detail: youtubeStatus) {
                            Button("Importă…") { model.isYouTubeSheetPresented = true }
                                .buttonStyle(TVGlassButtonStyle(height: 34))
                                .disabled(!isYouTubeReady)
                        }
                    }

                    SettingsGroup(title: "Stocare") {
                        SettingsRow(symbol: "internaldrive", title: "Biblioteca", detail: model.backendLocationLabel) {
                            Button("Arată în Finder") { model.revealLibraryInFinder() }
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
        case .efficient: "Fișiere mici, până la 1080p."
        case .native: "Echilibrat, până la 4K. Recomandat."
        case .original: "Fără redimensionare — fidelitate maximă."
        }
    }

    private var youtubeStatus: String {
        switch model.youtubeHelperStatus {
        case .unavailable: "Nu este inclus în această versiune."
        case let .ready(version): "Pregătit · \(version) · calitatea maximă disponibilă"
        case let .failed(reason): "Necesită atenție: \(reason)"
        }
    }

    private var screenSaverStatus: String {
        guard model.isScreenSaverInstalled else { return "Neinstalat" }
        guard model.integrations.isScreenSaverCurrent else { return "Există o versiune nouă" }
        return model.integrations.isScreenSaverSelected
            ? "Instalat și activ · rulează mereu fără sunet"
            : "Instalat · alege un wallpaper pentru Screen Saver"
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
            Text(isOn ? "Activ" : "De configurat")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(TV.secondaryText)
        }
    }
}
