import ServiceManagement
import SwiftUI
import WallpaperCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            StudioPageBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StudioPageTitle(
                        eyebrow: "Wallpaper Studio",
                        title: "Setări",
                        subtitle: "Controlează pornirea automată, calitatea și componentele sistemului."
                    )

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 18, alignment: .top),
                            GridItem(.flexible(), spacing: 18, alignment: .top)
                        ],
                        alignment: .leading,
                        spacing: 18
                    ) {
                        StudioCard {
                            VStack(alignment: .leading, spacing: 16) {
                                StudioSectionTitle(
                                    "Pornire automată",
                                    subtitle: "Păstrează wallpaperul Desktop activ după autentificare și când aplicația este închisă.",
                                    symbol: "power"
                                )
                                Divider()
                                Toggle(
                                    "Pornește cu Mac-ul",
                                    isOn: Binding(
                                        get: { model.isLoginItemEnabled },
                                        set: { model.setLoginItemEnabled($0) }
                                    )
                                )
                                HStack {
                                    Text("Renderer Desktop")
                                    Spacer()
                                    Text(model.isLoginItemEnabled ? "Activ" : "Oprit")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }

                        StudioCard {
                            VStack(alignment: .leading, spacing: 16) {
                                StudioSectionTitle(
                                    "Import local",
                                    subtitle: "Alege echilibrul dintre dimensiunea fișierului și fidelitatea imaginii.",
                                    symbol: "square.and.arrow.down"
                                )
                                Divider()
                                Picker("Calitate", selection: $model.importQuality) {
                                    Text("Eficient · până la 1080p").tag(MediaQuality.efficient)
                                    Text("Nativ · până la 4K").tag(MediaQuality.native)
                                    Text("Original · fără redimensionare").tag(MediaQuality.original)
                                }
                                .pickerStyle(.menu)
                                Text("Dacă recodarea nu este disponibilă, fișierul compatibil original este păstrat automat.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        StudioCard {
                            VStack(alignment: .leading, spacing: 16) {
                                StudioSectionTitle(
                                    "Screen Saver",
                                    subtitle: "Componenta separată pentru redare fluidă și întotdeauna fără sunet.",
                                    symbol: "sparkles.rectangle.stack"
                                )
                                Divider()
                                HStack {
                                    Text("Stare")
                                    Spacer()
                                    Text(screenSaverStatus)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                HStack {
                                    Button(model.isScreenSaverInstalled ? "Actualizează" : "Instalează") {
                                        model.installScreenSaver()
                                    }
                                    Spacer()
                                    Button("Setări macOS") {
                                        model.integrations.openScreenSaverSettings()
                                    }
                                }
                            }
                        }

                        StudioCard {
                            VStack(alignment: .leading, spacing: 16) {
                                StudioSectionTitle(
                                    "Import YouTube",
                                    subtitle: "Importă la calitatea maximă disponibilă conținutul pentru care ai permisiune.",
                                    symbol: "play.rectangle"
                                )
                                Divider()
                                HStack {
                                    Text("Componentă")
                                    Spacer()
                                    Text(youtubeStatus)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                HStack {
                                    Text("Calitate")
                                    Spacer()
                                    Text("Maxim disponibil")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                Button("Importă din YouTube…") {
                                    model.isYouTubeSheetPresented = true
                                }
                            }
                        }
                    }

                    StudioCard {
                        VStack(alignment: .leading, spacing: 16) {
                            StudioSectionTitle(
                                "Bibliotecă și stocare",
                                subtitle: "Toate fișierele pregătite de Wallpaper Studio sunt păstrate într-un singur loc.",
                                symbol: "internaldrive"
                            )
                            Divider()
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Locație")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(model.backendLocationLabel)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button("Arată în Finder") {
                                    model.revealLibraryInFinder()
                                }
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Setări")
        .tint(.primary)
    }

    private var youtubeStatus: String {
        switch model.youtubeHelperStatus {
        case .unavailable: "Indisponibilă"
        case let .ready(version): "Pregătită · \(version)"
        case .failed: "Necesită atenție"
        }
    }

    private var screenSaverStatus: String {
        guard model.isScreenSaverInstalled else { return "Neinstalat" }
        guard model.integrations.isScreenSaverCurrent else { return "Actualizare necesară" }
        return model.integrations.isScreenSaverSelected ? "Instalat și activ" : "Instalat · activează din Bibliotecă"
    }

}
