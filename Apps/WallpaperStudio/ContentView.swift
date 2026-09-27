import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "play.display")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(.white)
                        .background(.black, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Wallpaper Studio")
                            .font(.headline)
                        Text("Desktop · Lock Screen")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

                List(AppSection.allCases, selection: $model.selectedSection) { section in
                    HStack(spacing: 11) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 24)
                        Text(section.title)
                            .font(.callout.weight(.medium))
                    }
                    .padding(.vertical, 4)
                    .tag(section)
                }
                .listStyle(.sidebar)

                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        model.loginWallpaperStatus.isReady ? "Lock Screen pregătit" : "Configurare necesară",
                        systemImage: model.loginWallpaperStatus.isReady ? "checkmark.circle" : "circle.dashed"
                    )
                    Label(
                        model.displays.count == 1 ? "1 ecran conectat" : "\(model.displays.count) ecrane conectate",
                        systemImage: "display"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
        } detail: {
            Group {
                switch model.selectedSection ?? .library {
                case .library:
                    LibraryView()
                case .settings:
                    SettingsView()
                }
            }
            .overlay(alignment: .top) {
                messageOverlay
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $model.isYouTubeSheetPresented) {
            YouTubeImportView()
                .environmentObject(model)
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isApplying {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await model.lockNowWithWallpaperStudio() }
                } label: {
                    Label("Blochează", systemImage: "lock.display")
                }
                .help("Blochează cu fundalul Wallpaper Studio")
                .disabled(model.isApplying)
            }
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var messageOverlay: some View {
        if let message = model.bannerMessage {
            StatusBanner(message: message, style: .error) {
                model.dismissMessages()
            }
            .padding()
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if let message = model.successMessage {
            StatusBanner(message: message, style: .success) {
                model.dismissMessages()
            }
            .padding()
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct StatusBanner: View {
    enum Style {
        case error
        case success
    }

    let message: String
    let style: Style
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: style == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(.primary)
            Text(message)
                .font(.callout)
                .lineLimit(3)
            Spacer(minLength: 16)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Închide mesajul")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.6))
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .frame(maxWidth: 620)
    }
}
