import AppKit
import AVKit
import SwiftUI
import WallpaperCore

/// Apple TV-inspired library: one cinematic hero, horizontal shelves and
/// contextual configuration instead of a dense settings-first workflow.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var itemToDelete: MediaItem?
    @State private var itemToRename: MediaItem?
    @State private var renameText = ""

    private var visibleItems: [MediaItem] { model.filteredMediaItems }
    private var heroItem: MediaItem? { model.selectedMediaItem ?? visibleItems.first }

    var body: some View {
        ZStack {
            LibraryCanvasBackground()
            if model.isLoading {
                ProgressView("Se deschide biblioteca…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.mediaItems.isEmpty {
                TVEmptyLibrary(actionFiles: model.chooseFiles) { model.isYouTubeSheetPresented = true }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(32)
            } else if visibleItems.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        header.padding(.horizontal, 34).padding(.top, 26)
                        if let heroItem {
                            LibraryHeroStage(
                                item: heroItem,
                                urls: model.mediaURLs[heroItem.id],
                                configure: { model.configure(heroItem, for: $0) },
                                toggleFavorite: { model.toggleFavorite(heroItem) }
                            )
                            .id(heroItem.id)
                            .padding(.horizontal, 34)
                            .padding(.top, 24)
                            .transition(.opacity)

                            TVDestinationDock(
                                item: heroItem,
                                selectedDestination: model.selectedMediaID == heroItem.id ? model.selectedConfigurationDestination : nil,
                                select: { model.configure(heroItem, for: $0) }
                            )
                            .padding(.horizontal, 34)
                            .padding(.top, 18)
                        }
                        collectionShelf.padding(.top, 34)
                        if let selected = model.selectedMediaItem {
                            LibraryConfigurationPanel(item: selected)
                                .padding(.horizontal, 34)
                                .padding(.top, 28)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        importShelf
                            .padding(.horizontal, 34)
                            .padding(.top, 32)
                            .padding(.bottom, 36)
                    }
                    .frame(maxWidth: 1440)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }

            if !model.importJobs.isEmpty {
                VStack {
                    Spacer()
                    ImportActivityView(jobs: model.importJobs) { model.dismissImportJob($0) }
                        .frame(maxWidth: 540)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 18)
                }
            }
        }
        .navigationTitle("Bibliotecă")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Caută în Bibliotecă")
        .toolbar {
            ToolbarItemGroup {
                Button { model.isYouTubeSheetPresented = true } label: {
                    Label("YouTube", systemImage: "play.rectangle")
                }
                Button { model.chooseFiles() } label: {
                    Label("Importă", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls.filter(\.isFileURL))
            return !urls.isEmpty
        }
        .confirmationDialog(
            "Ștergi \(itemToDelete?.title ?? "acest element")?",
            isPresented: Binding(get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } })
        ) {
            Button("Șterge copia din Bibliotecă", role: .destructive) {
                if let itemToDelete { model.delete(itemToDelete) }
                itemToDelete = nil
            }
        } message: {
            Text("Fișierul original nu va fi modificat.")
        }
        .alert(
            "Redenumește",
            isPresented: Binding(get: { itemToRename != nil }, set: { if !$0 { itemToRename = nil } })
        ) {
            TextField("Nume", text: $renameText)
            Button("Salvează") {
                if let itemToRename { model.rename(itemToRename, to: renameText) }
                itemToRename = nil
            }
            Button("Anulează", role: .cancel) { itemToRename = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("COLECȚIA TA")
                    .font(.caption2.weight(.bold))
                    .tracking(2.2)
                    .foregroundStyle(.secondary)
                Text("Bibliotecă")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Text("Alege un wallpaper și transformă-l într-un spațiu al tău.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 18)
            HStack(spacing: 12) {
                TVLibraryFilter(selection: $model.libraryFilter)
                Text("\(visibleItems.count) \(visibleItems.count == 1 ? "element" : "elemente")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
    }

    private var collectionShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(shelfTitle).font(.title2.weight(.bold))
                    Text("Selectează pentru a deschide acțiunile și destinațiile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.libraryFilter != .all {
                    Button("Arată tot") { model.libraryFilter = .all }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 34)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(visibleItems) { item in
                        TVMediaCard(
                            item: item,
                            thumbnailURL: model.mediaURLs[item.id]?.thumbnail,
                            isSelected: model.selectedMediaID == item.id,
                            select: {
                                withAnimation(.snappy(duration: 0.25)) { model.selectedMediaID = item.id }
                            },
                            toggleFavorite: { model.toggleFavorite(item) }
                        )
                        .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var importShelf: some View {
        HStack(spacing: 14) {
            TVImportTile(title: "Adaugă fișiere", subtitle: "Imagine sau videoclip", symbol: "plus") {
                model.chooseFiles()
            }
            TVImportTile(title: "Importă din YouTube", subtitle: "Calitatea maximă disponibilă", symbol: "play.rectangle") {
                model.isYouTubeSheetPresented = true
            }
            Spacer(minLength: 0)
        }
    }

    private var shelfTitle: String {
        switch model.libraryFilter {
        case .all: "Colecția ta"
        case .videos: "Videoclipuri"
        case .images: "Imagini"
        case .favorites: "Favorite"
        }
    }

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        Menu("Configurează pentru", systemImage: "display.badge.checkmark") {
            Button("Desktop", systemImage: "desktopcomputer") { model.configure(item, for: .desktop) }
            Button("Screen Saver", systemImage: "sparkles.rectangle.stack") { model.configure(item, for: .screenSaver) }
            Button("Lock Screen", systemImage: "lock.display") { model.configure(item, for: .lockScreen) }
        }
        Divider()
        Button(item.isFavorite ? "Elimină din Favorite" : "Adaugă la Favorite") { model.toggleFavorite(item) }
        Button("Redenumește…") {
            renameText = item.title
            itemToRename = item
        }
        if let url = model.mediaURLs[item.id]?.prepared {
            Button("Arată în Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("Șterge din Bibliotecă…", role: .destructive) { itemToDelete = item }
    }
}

private struct LibraryCanvasBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.white.opacity(0.035), Color.clear, Color.black.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct TVLibraryFilter: View {
    @Binding var selection: LibraryFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LibraryFilter.allCases) { filter in
                Button(filter.title) { selection = filter }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selection == filter ? .primary : .secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(selection == filter ? Color.primary.opacity(0.14) : .clear, in: Capsule())
                    .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: Capsule())
        .overlay { Capsule().stroke(Color.primary.opacity(0.08)) }
    }
}

private struct LibraryHeroStage: View {
    let item: MediaItem
    let urls: MediaAssetURLs?
    let configure: (WallpaperDestination) -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork
                .frame(maxWidth: .infinity)
                .aspectRatio(2.2, contentMode: .fit)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.16), .black.opacity(0.94)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(item.kind == .video ? "VIDEO WALLPAPER" : "IMAGE WALLPAPER")
                        .font(.caption2.weight(.bold))
                        .tracking(1.9)
                        .foregroundStyle(.white.opacity(0.68))
                    Text(item.title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(detailLine).font(.callout).foregroundStyle(.white.opacity(0.72))
                }
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    Menu {
                        Button("Desktop") { configure(.desktop) }
                        Button("Screen Saver") { configure(.screenSaver) }
                        Button("Lock Screen") { configure(.lockScreen) }
                    } label: {
                        Label("Configurează", systemImage: "slider.horizontal.3")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .menuStyle(.borderlessButton)
                    .background(.white, in: Capsule())
                    Button(action: toggleFavorite) {
                        Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(28)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12)) }
        .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
    }

    @ViewBuilder
    private var artwork: some View {
        if item.kind == .video, let url = urls?.prepared {
            CinematicVideoPreview(url: url)
        } else if let poster = urls?.poster, let image = NSImage(contentsOf: poster) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(.black).overlay { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }
    }

    private var detailLine: String {
        var values = ["\(item.pixelSize.width) × \(item.pixelSize.height)"]
        if let duration = item.duration {
            let seconds = max(0, Int(duration.rounded()))
            values.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        if let codec = item.codec { values.append(codec.uppercased()) }
        return values.joined(separator: "  ·  ")
    }
}

private struct TVDestinationDock: View {
    let item: MediaItem
    let selectedDestination: WallpaperDestination?
    let select: (WallpaperDestination) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("APLICĂ ÎN")
                .font(.caption2.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .padding(.trailing, 5)
            ForEach(WallpaperDestination.allCases, id: \.self) { destination in
                Button { select(destination) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: destination.symbol)
                        Text(destination.shortTitle)
                        if selectedDestination == destination { Image(systemName: "checkmark").font(.caption2.bold()) }
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(selectedDestination == destination ? .primary : .secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(selectedDestination == destination ? Color.primary.opacity(0.14) : Color.primary.opacity(0.055), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Text(item.kind == .video ? "Video" : "Imagine")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct TVMediaCard: View {
    let item: MediaItem
    let thumbnailURL: URL?
    let isSelected: Bool
    let select: () -> Void
    let toggleFavorite: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    artwork.aspectRatio(16 / 9, contentMode: .fit).frame(width: 270).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
                    HStack(spacing: 6) {
                        Image(systemName: item.kind == .video ? "play.fill" : "photo.fill")
                        Text(item.kind == .video ? "VIDEO" : "IMAGINE")
                        if item.isFavorite { Image(systemName: "heart.fill") }
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(11)
                    if case .youtube = item.origin {
                        Image(systemName: "play.rectangle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(11)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(metaLine).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(7)
            .background(Color.primary.opacity(isSelected ? 0.11 : 0.001), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isSelected ? Color.primary.opacity(0.72) : Color.primary.opacity(isHovering ? 0.16 : 0), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.035 : 1)
        .animation(.snappy(duration: 0.2), value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu { Button(item.isFavorite ? "Elimină din Favorite" : "Adaugă la Favorite", action: toggleFavorite) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.kind == .video ? "video" : "imagine")")
    }

    @ViewBuilder
    private var artwork: some View {
        if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary).overlay { Image(systemName: item.kind == .video ? "film" : "photo").font(.title).foregroundStyle(.secondary) }
        }
    }

    private var metaLine: String {
        var values = ["\(item.pixelSize.width) × \(item.pixelSize.height)"]
        if let duration = item.duration {
            let seconds = max(0, Int(duration.rounded()))
            values.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        return values.joined(separator: "  ·  ")
    }
}

private struct LibraryConfigurationPanel: View {
    @EnvironmentObject private var model: AppModel
    let item: MediaItem

    private var destination: WallpaperDestination { model.selectedConfigurationDestination }
    private var configuration: Binding<DestinationConfiguration> {
        Binding(get: { model.draftProfile[destination] }, set: { model.draftProfile[destination] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configurează \(item.title)").font(.title2.weight(.bold))
                    Text("Setările sunt separate pentru fiecare destinație și se aplică doar când confirmi.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(destination.shortTitle.uppercased()).font(.caption2.weight(.bold)).tracking(1.3).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(WallpaperDestination.allCases, id: \.self) { value in
                    Button { model.configure(item, for: value) } label: {
                        Label(value.shortTitle, systemImage: value.symbol)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(destination == value ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(destination == value ? Color.primary.opacity(0.13) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                destinationDisplayCard
                destinationAudioCard
            }
            HStack(spacing: 12) {
                Label(statusText, systemImage: model.isApplying ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button("Închide") { model.selectedMediaID = nil }.buttonStyle(.borderless).foregroundStyle(.secondary)
                Button { Task { await model.applyFromLibrary(destination) } } label: {
                    Label(destination == .lockScreen ? "Aplică Lock Screen" : "Aplică \(destination.shortTitle)", systemImage: "checkmark")
                        .frame(minWidth: 152)
                }
                .buttonStyle(.borderedProminent).tint(.primary).disabled(model.isApplying)
            }
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.76), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.09)) }
    }

    private var destinationDisplayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVPanelHeading(title: "Ecrane", subtitle: "Toate sau un singur display", symbol: "display.2")
            HStack(spacing: 7) {
                TVChoiceButton(title: "Toate", isSelected: configuration.wrappedValue.displayTarget == .all) { configuration.wrappedValue.displayTarget = .all }
                TVChoiceButton(title: "Un ecran", isSelected: configuration.wrappedValue.displayTarget != .all) {
                    configuration.wrappedValue.displayTarget = .display(model.displays.first(where: \.isMain)?.id ?? model.displays.first?.id ?? "")
                }
            }
            if configuration.wrappedValue.displayTarget != .all, !model.displays.isEmpty {
                Picker("Ecran", selection: selectedDisplayBinding) {
                    ForEach(model.displays) { display in Text(displayLabel(display)).tag(display.id) }
                }
                .pickerStyle(.menu)
            }
            if model.displays.isEmpty {
                Label("Niciun ecran detectat", systemImage: "display.trianglebadge.exclamationmark").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var destinationAudioCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVPanelHeading(title: "Sunet", subtitle: destination == .screenSaver ? "Screen Saver este întotdeauna mut" : "Control separat pe destinație", symbol: destination == .screenSaver ? "speaker.slash" : "speaker.wave.2")
            if item.kind == .video, destination != .screenSaver {
                Toggle(destination == .lockScreen ? "Redă sunetul pe Lock Screen" : "Redă sunetul pe Desktop", isOn: audioBinding)
                    .toggleStyle(.switch)
                if !configuration.wrappedValue.muteVideo {
                    HStack(spacing: 9) {
                        Image(systemName: "speaker.wave.1")
                        Slider(value: volumeBinding, in: 0...1)
                        Text("\(Int(configuration.wrappedValue.volume * 100))%").font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                Label("Sunet dezactivat", systemImage: "speaker.slash.fill").font(.callout).foregroundStyle(.secondary)
            }
            if destination == .lockScreen {
                Text("Lock Screen folosește providerul nativ Wallpaper din macOS 26.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var selectedDisplayBinding: Binding<String> {
        Binding(
            get: { configuration.wrappedValue.displayTarget.explicitDisplayID ?? model.displays.first?.id ?? "" },
            set: { configuration.wrappedValue.displayTarget = .display($0) }
        )
    }

    private var audioBinding: Binding<Bool> {
        Binding(get: { !configuration.wrappedValue.muteVideo }, set: { configuration.wrappedValue.muteVideo = !$0 })
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { configuration.wrappedValue.volume }, set: { configuration.wrappedValue.volume = $0 })
    }

    private var statusText: String {
        if model.isApplying { return "Se aplică…" }
        if let ids = model.appliedDisplayIDs[destination], !ids.isEmpty { return "Configurare activă" }
        return "Gata de aplicare"
    }

    private func displayLabel(_ display: DisplayDescriptor) -> String { "\(display.name)\(display.isMain ? " · principal" : "")" }
}

private struct TVPanelHeading: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 28).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct TVChoiceButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Color.primary.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())
            .buttonStyle(.plain)
    }
}

private struct TVImportTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 34, height: 34).background(Color.primary.opacity(0.09), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)) }
        }
        .buttonStyle(.plain)
    }
}

private struct TVEmptyLibrary: View {
    let actionFiles: () -> Void
    let actionYouTube: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles.tv").font(.system(size: 42, weight: .medium)).foregroundStyle(.secondary).frame(width: 82, height: 82).background(Color.primary.opacity(0.07), in: Circle())
            VStack(spacing: 7) {
                Text("Construiește-ți colecția").font(.title2.weight(.bold))
                Text("Importă primul wallpaper și configurează-l separat pentru Desktop, Screen Saver sau Lock Screen.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 470)
            }
            HStack(spacing: 10) {
                Button("Alege fișiere…", action: actionFiles).buttonStyle(.borderedProminent)
                Button("Importă din YouTube…", action: actionYouTube)
            }
        }
    }
}

private struct CinematicVideoPreview: View {
    @StateObject private var playback: PreviewPlayback

    init(url: URL) { _playback = StateObject(wrappedValue: PreviewPlayback(url: url)) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PreviewPlayerSurface(player: playback.player)
            HStack(spacing: 9) {
                Button { playback.togglePlayback() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.plain)
                Text(playback.elapsedLabel).font(.caption.monospacedDigit())
                Slider(value: playback.progressBinding, in: 0...1).frame(width: 145)
                Text(playback.durationLabel).font(.caption.monospacedDigit())
                Button { playback.toggleMute() } label: { Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.black.opacity(0.58), in: Capsule())
            .padding(16)
        }
        .onDisappear { playback.stop() }
    }
}

@MainActor
private final class PreviewPlayback: ObservableObject {
    let player = AVQueuePlayer()
    @Published var isPlaying = true
    @Published var isMuted = true
    @Published var progress = 0.0
    @Published var elapsed = 0.0
    @Published var duration = 0.0
    private var looper: AVPlayerLooper?
    private var timeObserver: Any?

    init(url: URL) {
        player.isMuted = true
        player.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = max(0, time.seconds.isFinite ? time.seconds : 0)
                let itemDuration = self.player.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite, itemDuration > 0 { self.duration = itemDuration }
                self.progress = self.duration > 0 ? min(1, self.elapsed / self.duration) : 0
            }
        }
        player.play()
    }

    var progressBinding: Binding<Double> {
        Binding(get: { self.progress }, set: { value in
            guard self.duration > 0 else { return }
            self.player.seek(to: CMTime(seconds: value * self.duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        })
    }

    var elapsedLabel: String { Self.timeLabel(elapsed) }
    var durationLabel: String { Self.timeLabel(duration) }
    func togglePlayback() { isPlaying ? player.pause() : player.play(); isPlaying.toggle() }
    func toggleMute() { isMuted.toggle(); player.isMuted = isMuted }
    func stop() {
        player.pause()
        isPlaying = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        looper = nil
    }
    private static func timeLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct PreviewPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(); view.playerLayer.player = player; return view
    }
    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
            playerLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); playerLayer.frame = bounds }
    }
}

private struct ImportActivityView: View {
    let jobs: [ImportJob]
    let dismiss: (UUID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(jobs) { job in
                HStack(spacing: 10) {
                    if job.isFailed { Image(systemName: "exclamationmark.circle.fill") } else { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.title).font(.callout.weight(.medium))
                        Text(job.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if job.isFailed { Button { dismiss(job.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.09)) }
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }
}

private extension WallpaperDestination {
    var shortTitle: String {
        switch self {
        case .desktop: "Desktop"
        case .screenSaver: "Screen Saver"
        case .lockScreen: "Lock Screen"
        }
    }
    var symbol: String {
        switch self {
        case .desktop: "desktopcomputer"
        case .screenSaver: "sparkles.rectangle.stack"
        case .lockScreen: "lock.display"
        }
    }
}
