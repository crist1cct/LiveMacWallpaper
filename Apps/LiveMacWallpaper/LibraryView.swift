import SwiftUI
import WallpaperCore

/// "Library" — the whole collection as a poster grid. Filtering is a row of
/// capsules; search lives in the top bar; clicking any poster opens its page.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.layout) private var layout

    private var spacing: CGFloat { layout.isCompact ? 18 : 28 }
    private var minimumCardWidth: CGFloat { layout.isNarrow ? 200 : 240 }

    var body: some View {
        GeometryReader { proxy in
            let items = model.filteredMediaItems
            let grid = gridLayout(for: proxy.size.width)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 30) {
                    header(count: items.count)

                    if model.isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else if model.mediaItems.isEmpty {
                        EmptyLibraryView()
                            .frame(maxWidth: .infinity, minHeight: 420)
                    } else if items.isEmpty {
                        noResults
                    } else {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.fixed(grid.width), spacing: spacing, alignment: .top),
                                count: grid.columns
                            ),
                            alignment: .leading,
                            spacing: 36
                        ) {
                            ForEach(items) { item in
                                PosterCard(
                                    item: item,
                                    thumbnailURL: model.mediaURLs[item.id]?.thumbnail,
                                    width: grid.width,
                                    liveOn: model.activeDestinations(of: item)
                                ) {
                                    withAnimation(TV.pageSpring) { model.openDetail(item) }
                                }
                                .contextMenu { MediaContextMenu(item: item) }
                            }
                        }
                    }
                }
                .padding(.horizontal, layout.inset)
                .padding(.top, 96)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.never)
            .ignoresSafeArea(edges: .top)
        }
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Library")
                    .font(.system(size: layout.titleSize(40), weight: .bold))
                    .foregroundStyle(.white)
                Text(count == 1 ? "1 wallpaper" : "\(count) wallpapers")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(TV.tertiaryText)
                    .lineLimit(1)
                Spacer()
                Button { model.chooseFiles() } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(TVGlassButtonStyle(height: 38))
                .help("Import images or videos (⌘O)")
            }

            // Scrolls sideways instead of overflowing on narrow windows.
            ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(LibraryFilter.allCases) { filter in
                    FilterCapsule(title: filter.title, isSelected: model.libraryFilter == filter) {
                        withAnimation(.snappy(duration: 0.25)) { model.libraryFilter = filter }
                    }
                }
                if !model.searchText.isEmpty {
                    FilterCapsule(title: "“\(model.searchText)” ✕", isSelected: true) {
                        model.searchText = ""
                    }
                }
            }
            }
            .scrollIndicators(.never)
        }
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(TV.tertiaryText)
            Text("No Results")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Text("Try a different name or filter.")
                .foregroundStyle(TV.secondaryText)
            Button("Show All") {
                model.searchText = ""
                model.libraryFilter = .all
            }
            .buttonStyle(TVGlassButtonStyle(height: 38))
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private func gridLayout(for totalWidth: CGFloat) -> (columns: Int, width: CGFloat) {
        let available = max(minimumCardWidth, totalWidth - layout.inset * 2)
        let columns = max(1, Int((available + spacing) / (minimumCardWidth + spacing)))
        let width = (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return (columns, floor(width))
    }
}

private struct FilterCapsule: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background {
                    Capsule().fill(isSelected ? Color.white : Color.white.opacity(isHovering ? 0.16 : 0.08))
                }
                .scaleEffect(isHovering && !isSelected ? 1.05 : 1)
                .animation(TV.focusSpring, value: isHovering)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// First launch: explain the product in one sentence and offer the two ways in.
struct EmptyLibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.white)
                .frame(width: 112, height: 112)
                .tvGlass(in: Circle())
            VStack(spacing: 8) {
                Text("Welcome to Live Mac Wallpaper")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text("Add a video or an image and put it on your Desktop, Screen Saver or Lock Screen in one click.")
                    .font(.system(size: 15))
                    .foregroundStyle(TV.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            HStack(spacing: 12) {
                Button { model.chooseFiles() } label: {
                    Label("Choose Files", systemImage: "plus")
                }
                .buttonStyle(TVPrimaryButtonStyle())
                Button { model.isYouTubeSheetPresented = true } label: {
                    Label("From YouTube", systemImage: "play.rectangle.fill")
                }
                .buttonStyle(TVGlassButtonStyle())
            }
            Text("You can also drop files anywhere in the window. Originals are never modified.")
                .font(.system(size: 12))
                .foregroundStyle(TV.tertiaryText)
        }
        .padding(40)
    }
}
