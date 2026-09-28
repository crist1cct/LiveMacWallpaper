import SwiftUI
import WallpaperCore

struct YouTubeImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var metadata: YouTubeMetadata?
    @State private var hasConfirmedRights = false
    @State private var isChecking = false
    @State private var isImporting = false
    @State private var phase = ""
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            TV.canvas.ignoresSafeArea()
            if let thumbnail = metadata?.thumbnailURL {
                // The clip's own artwork, blurred, as the sheet's backdrop.
                AsyncImage(url: thumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .blur(radius: 60)
                .opacity(0.45)
                .ignoresSafeArea()
                .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .tvGlass(in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import from YouTube")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Paste a video link. It's prepared automatically at the highest quality.")
                            .font(.system(size: 13))
                            .foregroundStyle(TV.secondaryText)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(TVGlassButtonStyle(circle: true, height: 34))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                    .help("Close (Esc)")
                }

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
                    importForm
                }
            }
            .padding(30)
        }
        .frame(width: 660, height: 580)
        .preferredColorScheme(.dark)
        .animation(TV.pageSpring, value: metadata?.title)
    }

    private func unavailable(title: String, symbol: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(TV.tertiaryText)
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            Text(message).font(.system(size: 13)).foregroundStyle(TV.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var importForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(TV.secondaryText)
                    TextField("https://www.youtube.com/watch?v=…", text: $urlText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .onChange(of: urlText) {
                            metadata = nil
                            hasConfirmedRights = false
                            errorMessage = nil
                        }
                        .onSubmit { Task { await inspect() } }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .tvGlassCapsule()

                Button {
                    Task { await inspect() }
                } label: {
                    if isChecking {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text("Check")
                    }
                }
                .buttonStyle(TVGlassButtonStyle(height: 44))
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            }

            if let metadata {
                HStack(alignment: .top, spacing: 16) {
                    AsyncImage(url: metadata.thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(Color.white.opacity(0.08))
                    }
                    .frame(width: 208, height: 117)
                    .clipShape(RoundedRectangle(cornerRadius: TV.cardRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(metadata.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                        if let channel = metadata.channel {
                            Text(channel).font(.system(size: 13)).foregroundStyle(TV.secondaryText)
                        }
                        HStack(spacing: 6) {
                            if let duration = metadata.duration {
                                Text(TV.timeLabel(duration))
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                    .foregroundStyle(TV.secondaryText)
                            }
                            TVBadge(text: "MAX")
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

                Toggle(isOn: $hasConfirmedRights) {
                    Text("I confirm that this download is authorized by YouTube functionality or that I have the necessary written permission from YouTube and the rights holders.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)

                HStack(spacing: 4) {
                    Text("Single videos only: no playlists, cookies, sign-in or DRM.")
                    Link("YouTube Terms", destination: URL(string: "https://www.youtube.com/static?template=terms")!)
                        .foregroundStyle(.white)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(TV.tertiaryText)
            } else if !isChecking {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Works with videos, Shorts and youtu.be links.", systemImage: "checkmark")
                    Label("Downloads the highest available resolution.", systemImage: "checkmark")
                    Label("Incompatible formats are converted automatically.", systemImage: "checkmark")
                }
                .font(.system(size: 13))
                .foregroundStyle(TV.secondaryText)
                .padding(.top, 4)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.yellow)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                if isImporting {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(phase)
                        .font(.system(size: 13))
                        .foregroundStyle(TV.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    Task { await importVideo() }
                } label: {
                    Label("Add to Library", systemImage: "arrow.down")
                }
                .buttonStyle(TVPrimaryButtonStyle())
                .disabled(metadata == nil || !hasConfirmedRights || isImporting)
            }
        }
    }

    private func inspect() async {
        isChecking = true
        errorMessage = nil
        metadata = nil
        defer { isChecking = false }
        do {
            metadata = try await model.inspectYouTube(urlText)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func importVideo() async {
        isImporting = true
        phase = "Preparing"
        errorMessage = nil
        do {
            try await model.importYouTube(urlText) { newPhase in
                phase = newPhase
            }
            model.successMessage = "Video added to the Library."
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isImporting = false
    }


}
