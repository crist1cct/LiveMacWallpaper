import SwiftUI
import WallpaperCore

/// One-step YouTube import: paste a link, confirm the rights once, press Install.
/// The video info appears while it downloads; the install keeps running in the
/// background if the sheet is closed.
struct YouTubeImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var hasConfirmedRights = false
    @FocusState private var isFieldFocused: Bool

    private var install: YouTubeInstall? { model.youtubeInstall }

    private var linkIsValid: Bool {
        (try? YouTubeURL(urlText.trimmingCharacters(in: .whitespacesAndNewlines))) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            switch model.youtubeHelperStatus {
            case .unavailable:
                unavailable(
                    title: "Import Unavailable",
                    symbol: "shippingbox",
                    message: "YouTube import isn't included in this build of the app."
                )
            case let .failed(reason):
                unavailable(title: "The Component Can't Start", symbol: "exclamationmark.triangle", message: reason)
            case .ready:
                if let install {
                    InstallProgressCard(install: install)
                    Spacer(minLength: 0)
                    installFooter(install)
                } else {
                    form
                    Spacer(minLength: 0)
                    formFooter
                }
            }
        }
        .padding(28)
        .frame(minWidth: 480, idealWidth: 600, maxWidth: 720, minHeight: 400, idealHeight: 460)
        // Backdrop lives in the background so it can never change the sheet's size.
        .background { backdrop }
        .preferredColorScheme(.dark)
        .animation(TV.pageSpring, value: install)
        .onAppear {
            if install == nil { isFieldFocused = true }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .tvGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from YouTube")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("Downloaded at the highest available quality and added to your Library.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(TV.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(TVGlassButtonStyle(circle: true, height: 32))
            .keyboardShortcut(.cancelAction)
            .help(install?.isRunning == true ? "Close — the download continues in the background" : "Close (Esc)")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(TV.secondaryText)
                TextField("Paste a YouTube link", text: $urlText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .focused($isFieldFocused)
                    .onSubmit(startInstall)
                if !urlText.isEmpty {
                    Image(systemName: linkIsValid ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(linkIsValid ? Color.green : Color.yellow)
                        .help(linkIsValid ? "Valid link" : "Not a single YouTube video link")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .tvGlassCapsule()

            Toggle(isOn: $hasConfirmedRights) {
                Text("I confirm that this download is authorized by YouTube functionality or that I have the necessary written permission from YouTube and the rights holders.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 6) {
                Label("Videos, Shorts and youtu.be links", systemImage: "checkmark")
                Label("Highest available resolution; incompatible formats are converted", systemImage: "checkmark")
                Label("Single videos only: no playlists, cookies, sign-in or DRM", systemImage: "checkmark")
            }
            .font(.system(size: 12))
            .foregroundStyle(TV.tertiaryText)

            Link("YouTube Terms of Service", destination: URL(string: "https://www.youtube.com/static?template=terms")!)
                .font(.system(size: 11.5))
                .foregroundStyle(TV.secondaryText)
        }
    }

    private var formFooter: some View {
        HStack {
            Spacer()
            Button(action: startInstall) {
                Label("Install", systemImage: "arrow.down")
                    .frame(minWidth: 120)
            }
            .buttonStyle(TVPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!linkIsValid || !hasConfirmedRights)
        }
    }

    @ViewBuilder
    private func installFooter(_ install: YouTubeInstall) -> some View {
        HStack(spacing: 10) {
            Spacer()
            if install.isRunning {
                Button("Continue in Background") { dismiss() }
                    .buttonStyle(TVGlassButtonStyle(height: 40))
            } else if install.failure != nil {
                Button("Try Another Link") {
                    model.resetYouTubeInstall()
                    hasConfirmedRights = false
                }
                .buttonStyle(TVGlassButtonStyle(height: 40))
                Button("Retry") {
                    let url = install.url
                    model.resetYouTubeInstall()
                    model.installYouTube(url)
                }
                .buttonStyle(TVPrimaryButtonStyle())
            } else {
                Button("Import Another") {
                    model.resetYouTubeInstall()
                    urlText = ""
                    hasConfirmedRights = false
                }
                .buttonStyle(TVGlassButtonStyle(height: 40))
                Button("Done") {
                    model.resetYouTubeInstall()
                    dismiss()
                }
                .buttonStyle(TVPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func unavailable(title: String, symbol: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(TV.tertiaryText)
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(TV.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backdrop: some View {
        ZStack {
            TV.canvas
            if let thumbnail = install?.metadata?.thumbnailURL {
                AsyncImage(url: thumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .fillWithoutOverflow()
                .blur(radius: 60)
                .opacity(0.4)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
    }

    private func startInstall() {
        guard linkIsValid, hasConfirmedRights else { return }
        model.installYouTube(urlText)
    }
}

/// Thumbnail, title and live progress for the running install.
private struct InstallProgressCard: View {
    let install: YouTubeInstall

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                if let thumbnail = install.metadata?.thumbnailURL {
                    AsyncImage(url: thumbnail) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                } else {
                    Color.white.opacity(0.08)
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .fillWithoutOverflow()
            .frame(width: 192, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: TV.cardRadius, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(install.metadata?.title ?? install.url)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let channel = install.metadata?.channel {
                        Text(channel).lineLimit(1)
                    }
                    if let duration = install.metadata?.duration {
                        Text("· " + TV.timeLabel(duration))
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(TV.secondaryText)

                status
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .tvGlass(in: RoundedRectangle(cornerRadius: TV.panelRadius, style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        if let failure = install.failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(.yellow)
                .fixedSize(horizontal: false, vertical: true)
        } else if install.isFinished {
            Label("Added to Library", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text(install.phase)
                    .font(.system(size: 12.5))
                    .foregroundStyle(TV.secondaryText)
                    .lineLimit(1)
            }
            if let fraction = Self.fraction(in: install.phase) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(maxWidth: 260)
            }
        }
    }

    /// Import phases carry a percentage ("Downloading · 42%").
    private static func fraction(in phase: String) -> Double? {
        guard let percent = phase.split(separator: "·").last?
            .trimmingCharacters(in: .whitespaces)
            .dropLast(), phase.hasSuffix("%"),
            let value = Double(percent)
        else { return nil }
        return min(1, max(0, value / 100))
    }
}
