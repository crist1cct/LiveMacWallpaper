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
            StudioPageBackground()
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Importă din YouTube")
                            .font(.title2.bold())
                        Text("Calitatea maximă disponibilă, pregătită automat pentru redare.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Închide") { dismiss() }
                        .disabled(isImporting)
                }

                StudioPanel(padding: 20) {
                    switch model.youtubeHelperStatus {
                    case .unavailable:
                        ContentUnavailableView(
                            "Import indisponibil",
                            systemImage: "shippingbox",
                            description: Text("Componenta YouTube nu este inclusă în acest build.")
                        )
                    case let .failed(reason):
                        ContentUnavailableView(
                            "Componenta nu poate porni",
                            systemImage: "exclamationmark.triangle",
                            description: Text(reason)
                        )
                    case .ready:
                        importForm
                    }
                }
            }
            .padding(26)
        }
        .frame(width: 640, height: 560)
    }

    private var importForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("https://www.youtube.com/watch?v=…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: urlText) {
                        metadata = nil
                        hasConfirmedRights = false
                        errorMessage = nil
                    }
                    .onSubmit { Task { await inspect() } }
                Button("Verifică linkul") {
                    Task { await inspect() }
                }
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            }

            if isChecking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Se citește informația video…")
                        .foregroundStyle(.secondary)
                }
            }

            if let metadata {
                HStack(alignment: .top, spacing: 14) {
                    AsyncImage(url: metadata.thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                    .frame(width: 170, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(metadata.title)
                            .font(.headline)
                            .lineLimit(2)
                        if let channel = metadata.channel {
                            Text(channel).foregroundStyle(.secondary)
                        }
                        if let duration = metadata.duration {
                            Text(Self.durationLabel(duration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle(isOn: $hasConfirmedRights) {
                    Text("Confirm că descărcarea este autorizată de funcționalitatea YouTube sau că am permisiunile scrise necesare de la YouTube și deținătorii drepturilor.")
                        .font(.callout)
                }

                HStack(spacing: 4) {
                    Text("Se importă un singur clip, fără playlisturi, cookies, login sau DRM.")
                    Link("Termenii YouTube", destination: URL(string: "https://www.youtube.com/static?template=terms")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("Pregătire") {
                    Text("Maxim disponibil · fără limită de rezoluție")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.primary)
            }

            Spacer()

            if isImporting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(phase)
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button("Anulează") { dismiss() }
                    .disabled(isImporting)
                Button("Importă") {
                    Task { await importVideo() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .disabled(metadata == nil || !hasConfirmedRights || isImporting)
            }
        }
        .tint(.primary)
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
        phase = "Se pregătește"
        errorMessage = nil
        do {
            try await model.importYouTube(urlText) { newPhase in
                phase = newPhase
            }
            model.successMessage = "Clipul a fost adăugat în Bibliotecă."
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isImporting = false
    }

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

}
