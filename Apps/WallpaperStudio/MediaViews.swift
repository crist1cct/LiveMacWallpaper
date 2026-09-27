import AppKit
import AVFoundation
import SwiftUI
import WallpaperCore

/// Full-bleed artwork for heroes and detail pages: a silent looping video for video
/// wallpapers (after a short delay, so scrolling stays smooth), the poster
/// for images and while the video spins up.
struct MotionBackdrop: View {
    let item: MediaItem
    let urls: MediaAssetURLs?
    var playsVideo = true
    @Binding var isMuted: Bool
    @State private var showsVideo = false

    init(item: MediaItem, urls: MediaAssetURLs?, playsVideo: Bool = true, isMuted: Binding<Bool> = .constant(true)) {
        self.item = item
        self.urls = urls
        self.playsVideo = playsVideo
        _isMuted = isMuted
    }

    var body: some View {
        ZStack {
            ArtworkImage(url: urls?.poster ?? urls?.thumbnail, symbol: item.kind == .video ? "film" : "photo")
            if playsVideo, item.kind == .video, let url = urls?.prepared {
                LoopingVideoView(url: url, isMuted: isMuted)
                    .opacity(showsVideo ? 1 : 0)
            }
        }
        .task(id: item.id) {
            showsVideo = false
            guard playsVideo, item.kind == .video else { return }
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) { showsVideo = true }
        }
    }
}

/// Muted-by-default looping player surface.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var isMuted = true

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.load(url)
        view.setMuted(isMuted)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.load(url)
        view.setMuted(isMuted)
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.teardown()
    }

    final class PlayerView: NSView {
        private let playerLayer = AVPlayerLayer()
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var currentURL: URL?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func load(_ url: URL) {
            guard url != currentURL else { return }
            teardown()
            currentURL = url
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            playerLayer.player = player
            self.player = player
            player.play()
        }

        func setMuted(_ muted: Bool) {
            player?.isMuted = muted
        }

        func teardown() {
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player?.removeAllItems()
            playerLayer.player = nil
            player = nil
            currentURL = nil
        }
    }
}

/// A 16:9 poster card with a hover focus lift. The title sits under the card and
/// brightens on focus.
struct PosterCard: View {
    let item: MediaItem
    let thumbnailURL: URL?
    var width: CGFloat = 300
    var liveOn: [WallpaperDestination] = []
    let open: () -> Void
    @State private var isHovering = false

    init(
        item: MediaItem,
        thumbnailURL: URL?,
        width: CGFloat = 300,
        liveOn: [WallpaperDestination] = [],
        open: @escaping () -> Void
    ) {
        self.item = item
        self.thumbnailURL = thumbnailURL
        self.width = width
        self.liveOn = liveOn
        self.open = open
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkImage(url: thumbnailURL, symbol: item.kind == .video ? "film" : "photo")
                        .frame(width: width, height: width * 9 / 16)

                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)

                    HStack(spacing: 6) {
                        if item.kind == .video {
                            Image(systemName: "play.fill")
                        }
                        if let duration = item.duration {
                            Text(TV.timeLabel(duration))
                        }
                        Spacer(minLength: 0)
                        if item.isFavorite {
                            Image(systemName: "heart.fill")
                        }
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(10)

                    if !liveOn.isEmpty {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("LIVE")
                        }
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .tvGlassCapsule()
                        .padding(9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(width: width, height: width * 9 / 16)
                .tvFocus(isHovering)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isHovering ? TV.primaryText : TV.secondaryText)
                        .lineLimit(1)
                    Text(item.metaLine)
                        .font(.system(size: 12))
                        .foregroundStyle(TV.tertiaryText)
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
                .offset(y: isHovering ? 6 : 0)
                .animation(TV.focusSpring, value: isHovering)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.kindLabel)")
        .accessibilityHint("Opens the wallpaper page")
    }
}

/// Horizontal, view-aligned shelf of posters.
struct PosterShelf: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    var subtitle: String?
    let items: [MediaItem]
    var cardWidth: CGFloat = 300
    var seeAll: (() -> Void)?

    init(
        title: String,
        subtitle: String? = nil,
        items: [MediaItem],
        cardWidth: CGFloat = 300,
        seeAll: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.cardWidth = cardWidth
        self.seeAll = seeAll
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TVShelfHeader(
                title: title,
                subtitle: subtitle,
                action: seeAll.map { (title: "See All", run: $0) }
            )
            .padding(.horizontal, TV.pageInset)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(items) { item in
                        PosterCard(
                            item: item,
                            thumbnailURL: model.mediaURLs[item.id]?.thumbnail,
                            width: cardWidth,
                            liveOn: model.activeDestinations(of: item)
                        ) {
                            withAnimation(TV.pageSpring) { model.openDetail(item) }
                        }
                        .contextMenu { MediaContextMenu(item: item) }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, TV.pageInset)
                // Room for the focus lift and its shadow.
                .padding(.vertical, 22)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .padding(.vertical, -22)
        }
    }
}

/// Shared right-click menu for a wallpaper.
struct MediaContextMenu: View {
    @EnvironmentObject private var model: AppModel
    let item: MediaItem

    init(item: MediaItem) {
        self.item = item
    }

    var body: some View {
        Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") {
            withAnimation(TV.pageSpring) { model.openDetail(item) }
        }
        Menu("Set on…", systemImage: "rectangle.on.rectangle") {
            ForEach(WallpaperDestination.allCases, id: \.self) { destination in
                Button(destination.title, systemImage: destination.symbol) {
                    model.configure(item, for: destination)
                    Task { await model.applyFromLibrary(destination) }
                }
            }
        }
        .disabled(model.isApplying)
        Divider()
        Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: item.isFavorite ? "heart.slash" : "heart") {
            model.toggleFavorite(item)
        }
        if let url = model.mediaURLs[item.id]?.prepared {
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
