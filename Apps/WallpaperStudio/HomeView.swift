import SwiftUI
import WallpaperCore

/// "Acasă" — the Apple TV "Watch Now" of Wallpaper Studio: one cinematic hero,
/// what is live on each surface right now, then shelves.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 46) {
                    if let hero = model.featuredItem {
                        HomeHero(item: hero, height: max(460, proxy.size.height * 0.74))
                    }

                    NowShowingRow()
                        .padding(.horizontal, TV.pageInset)

                    let favorites = model.mediaItems.filter(\.isFavorite)
                    if !favorites.isEmpty {
                        PosterShelf(title: "Favorite", items: favorites) {
                            model.libraryFilter = .favorites
                            withAnimation(TV.pageSpring) { model.selectedSection = .library }
                        }
                    }

                    let videos = model.recentItems.filter { $0.kind == .video }
                    if !videos.isEmpty {
                        PosterShelf(title: "Wallpapere animate", subtitle: "\(videos.count)", items: videos) {
                            model.libraryFilter = .videos
                            withAnimation(TV.pageSpring) { model.selectedSection = .library }
                        }
                    }

                    let images = model.recentItems.filter { $0.kind == .image }
                    if !images.isEmpty {
                        PosterShelf(title: "Imagini", subtitle: "\(images.count)", items: images, cardWidth: 250) {
                            model.libraryFilter = .images
                            withAnimation(TV.pageSpring) { model.selectedSection = .library }
                        }
                    }

                    AddContentRow()
                        .padding(.horizontal, TV.pageInset)
                        .padding(.bottom, 60)
                }
            }
            .scrollIndicators(.never)
            .ignoresSafeArea(edges: .top)
        }
    }
}

// MARK: - Hero

private struct HomeHero: View {
    @EnvironmentObject private var model: AppModel
    let item: MediaItem
    let height: CGFloat
    @State private var isMuted = true

    private var isOnDesktop: Bool { model.activeMedia(for: .desktop)?.id == item.id }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MotionBackdrop(item: item, urls: model.mediaURLs[item.id], isMuted: $isMuted)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipped()
                .id(item.id)

            // Legibility scrims: bottom fade into the canvas + left vignette.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: TV.canvas.opacity(0.65), location: 0.75),
                    .init(color: TV.canvas, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: UnitPoint(x: 0.6, y: 0.5)
            )
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2))

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(isOnDesktop ? "ACUM PE DESKTOP" : "RECOMANDAT PENTRU TINE")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(TV.secondaryText)

                    Text(item.title)
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.4), radius: 12)

                    HStack(spacing: 8) {
                        Text(item.metaLine)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(TV.secondaryText)
                        ForEach(item.badges, id: \.self) { TVBadge(text: $0) }
                    }

                    HStack(spacing: 12) {
                        if isOnDesktop {
                            Button {
                                withAnimation(TV.pageSpring) { model.openDetail(item, destination: .desktop) }
                            } label: {
                                Label("Configurează", systemImage: "slider.horizontal.3")
                            }
                            .buttonStyle(TVPrimaryButtonStyle())
                        } else {
                            Button {
                                model.configure(item, for: .desktop)
                                Task { await model.applyFromLibrary(.desktop) }
                            } label: {
                                Label("Setează pe Desktop", systemImage: "play.fill")
                            }
                            .buttonStyle(TVPrimaryButtonStyle())
                            .disabled(model.isApplying)

                            Button {
                                withAnimation(TV.pageSpring) { model.openDetail(item) }
                            } label: {
                                Text("Mai multe")
                            }
                            .buttonStyle(TVGlassButtonStyle())
                        }

                        Button { model.toggleFavorite(item) } label: {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                        }
                        .buttonStyle(TVGlassButtonStyle(circle: true))
                        .help(item.isFavorite ? "Elimină din Favorite" : "Adaugă la Favorite")
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: 620, alignment: .leading)

                Spacer(minLength: 20)

                if item.kind == .video {
                    Button { isMuted.toggle() } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(TVGlassButtonStyle(circle: true, height: 40))
                    .help(isMuted ? "Pornește sunetul previzualizării" : "Oprește sunetul")
                }
            }
            .padding(.horizontal, TV.pageInset)
            .padding(.bottom, 36)
        }
        .frame(height: height)
    }
}

// MARK: - Now showing

/// What is live on each surface, at a glance. Each tile opens the right page.
private struct NowShowingRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TVShelfHeader(title: "Acum pe ecranele tale")
            HStack(spacing: 24) {
                ForEach(WallpaperDestination.allCases, id: \.self) { destination in
                    SurfaceTile(destination: destination, item: model.activeMedia(for: destination))
                }
            }
        }
    }
}

private struct SurfaceTile: View {
    @EnvironmentObject private var model: AppModel
    let destination: WallpaperDestination
    let item: MediaItem?
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                if let item {
                    ArtworkImage(url: model.mediaURLs[item.id]?.thumbnail)
                } else {
                    LinearGradient(
                        colors: [Color.white.opacity(0.09), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(TV.tertiaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 10) {
                    Image(systemName: destination.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .tvGlass(in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(destination.title)
                            .font(.system(size: 14, weight: .bold))
                        Text(item?.title ?? "Nesetat · alege un wallpaper")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TV.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.applyingDestination == destination {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .tvFocus(isHovering, scale: 1.04)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(destination.title): \(item?.title ?? "nesetat")")
    }

    private func open() {
        if let item {
            withAnimation(TV.pageSpring) { model.openDetail(item, destination: destination) }
        } else {
            withAnimation(TV.pageSpring) { model.selectedSection = .library }
        }
    }
}

// MARK: - Add content

struct AddContentRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 20) {
            AddTile(title: "Adaugă din Mac", subtitle: "Imagini și videoclipuri · sau trage-le aici", symbol: "plus") {
                model.chooseFiles()
            }
            AddTile(title: "Importă din YouTube", subtitle: "La calitatea maximă disponibilă", symbol: "play.rectangle.fill") {
                model.isYouTubeSheetPresented = true
            }
        }
    }
}

private struct AddTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(TV.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(isHovering ? 0.1 : 0.055))
            .tvFocus(isHovering, cornerRadius: 18, scale: 1.02)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
