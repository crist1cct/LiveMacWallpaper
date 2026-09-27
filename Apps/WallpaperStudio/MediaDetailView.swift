import AppKit
import SwiftUI
import WallpaperCore

/// Full-window page for one wallpaper: the
/// artwork plays behind everything, details and the single primary action sit on
/// the left, and each surface (Desktop / Screen Saver / Lock Screen) is one click.
struct MediaDetailView: View {
    @EnvironmentObject private var model: AppModel
    let item: MediaItem

    @State private var isMuted = true
    @State private var isPreviewing = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false

    init(item: MediaItem) {
        self.item = item
    }

    private var destination: WallpaperDestination { model.selectedConfigurationDestination }
    private var liveOn: [WallpaperDestination] { model.activeDestinations(of: item) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TV.canvas.ignoresSafeArea()

            MotionBackdrop(item: item, urls: model.mediaURLs[item.id], isMuted: $isMuted)
                .ignoresSafeArea()
                .id(item.id)

            if !isPreviewing {
                scrims.transition(.opacity)
                content.transition(.move(edge: .leading).combined(with: .opacity))
                closeButton.transition(.opacity)
            } else {
                previewHint.transition(.opacity)
            }
        }
        .background {
            // Esc closes the page (or leaves preview first).
            Button("") { escape() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Save") { model.rename(item, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(item.title)” from the Library?", isPresented: $isConfirmingDelete) {
            Button("Delete from Library", role: .destructive) {
                model.delete(item)
            }
        } message: {
            Text("Only the Wallpaper Studio copy is deleted. The original file is not touched.")
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Layers

    private var scrims: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.88), location: 0),
                    .init(color: .black.opacity(0.62), location: 0.38),
                    .init(color: .clear, location: 0.72)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: UnitPoint(x: 0.5, y: 0.55), endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var closeButton: some View {
        HStack(spacing: 10) {
            Button { close() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(TVGlassButtonStyle(circle: true, height: 40))
            .help("Back (Esc)")

            Spacer()

            if item.kind == .video {
                Button { isMuted.toggle() } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(TVGlassButtonStyle(circle: true, height: 40))
                .help(isMuted ? "Play clip audio" : "Mute")
            }
            Button {
                withAnimation(TV.pageSpring) { isPreviewing = true }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(TVGlassButtonStyle(circle: true, height: 40))
            .help("Full-window preview")
        }
        .padding(.leading, 84) // clear of the window's traffic lights
        .padding(.trailing, 28)
        .padding(.top, 14)
    }

    private var previewHint: some View {
        VStack {
            Spacer()
            Text("Click anywhere or press Esc to return")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .tvGlassCapsule()
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(TV.pageSpring) { isPreviewing = false } }
    }

    private var content: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 26) {
                    titleBlock
                    DestinationPicker(selection: destination, liveOn: liveOn) { value in
                        withAnimation(.snappy(duration: 0.25)) { model.configure(item, for: value) }
                    }
                    OptionsPanel(item: item, destination: destination)
                    actions
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, TV.pageInset)
                .padding(.top, 90)
                .padding(.bottom, 48)
                // Sit at the bottom-left like a title page; scroll only when the window is short.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .bottomLeading)
            }
            .scrollIndicators(.never)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(item.kind == .video ? "MOTION WALLPAPER" : "IMAGE")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(TV.secondaryText)
                if item.isFromYouTube {
                    TVBadge(text: "YOUTUBE")
                }
            }
            Text(item.title)
                .font(.system(size: 50, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
            HStack(spacing: 8) {
                Text(item.metaLine)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TV.secondaryText)
                ForEach(item.badges, id: \.self) { TVBadge(text: $0) }
            }
            if !liveOn.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Active on " + liveOn.map(\.title).joined(separator: ", "))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 2)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.applyFromLibrary(destination) }
            } label: {
                HStack(spacing: 8) {
                    if model.isApplying {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Image(systemName: "checkmark")
                    }
                    Text(model.isApplying ? "Applying…" : destination.applyTitle)
                }
                .frame(minWidth: 200)
            }
            .buttonStyle(TVPrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: [])
            .disabled(model.isApplying)

            Button { model.toggleFavorite(item) } label: {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(TVGlassButtonStyle(circle: true))
            .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")

            Menu {
                Button("Rename…", systemImage: "pencil") {
                    renameText = item.title
                    isRenaming = true
                }
                if let url = model.mediaURLs[item.id]?.prepared {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                if case let .youtube(_, webpage, _) = item.origin {
                    Button("Open on YouTube", systemImage: "play.rectangle") {
                        NSWorkspace.shared.open(webpage)
                    }
                }
                Divider()
                Button("Delete from Library…", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .tvGlass(in: Circle(), interactive: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    // MARK: Navigation

    private func escape() {
        if isPreviewing {
            withAnimation(TV.pageSpring) { isPreviewing = false }
        } else {
            close()
        }
    }

    private func close() {
        withAnimation(TV.pageSpring) { model.closeDetail() }
    }
}

// MARK: - Destination picker

/// Three large surface buttons; the chosen one is filled white.
private struct DestinationPicker: View {
    let selection: WallpaperDestination
    let liveOn: [WallpaperDestination]
    let select: (WallpaperDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DESTINATION")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(TV.tertiaryText)
            HStack(spacing: 10) {
                ForEach(WallpaperDestination.allCases, id: \.self) { destination in
                    DestinationButton(
                        destination: destination,
                        isSelected: destination == selection,
                        isLive: liveOn.contains(destination)
                    ) { select(destination) }
                }
            }
        }
    }
}

private struct DestinationButton: View {
    let destination: WallpaperDestination
    let isSelected: Bool
    let isLive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 24)
                Text(destination.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isSelected ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.14 : 0.07))
                }
            }
            .overlay(alignment: .topTrailing) {
                if isLive {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                        .padding(10)
                        .accessibilityLabel("activ")
                }
            }
            .scaleEffect(isSelected ? 1.03 : (isHovering ? 1.03 : 1))
            .shadow(color: .black.opacity(isSelected ? 0.4 : 0), radius: 16, y: 8)
            .animation(TV.focusSpring, value: isHovering)
            .animation(TV.focusSpring, value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Options

/// The few settings that matter for the chosen surface, in plain language.
private struct OptionsPanel: View {
    @EnvironmentObject private var model: AppModel
    let item: MediaItem
    let destination: WallpaperDestination

    private var configuration: Binding<DestinationConfiguration> {
        Binding(
            get: { model.draftProfile[destination] },
            set: { model.draftProfile[destination] = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            displaysRow
            Divider().overlay(TV.hairline).padding(.vertical, 14)
            soundRow
            if destination == .lockScreen {
                Text("The Lock Screen uses the native macOS 26 wallpaper provider. Audio starts only once the screen is locked and stops immediately on unlock.")
                    .font(.system(size: 12))
                    .foregroundStyle(TV.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
        .padding(20)
        .tvGlass(in: RoundedRectangle(cornerRadius: TV.panelRadius, style: .continuous))
    }

    private var displaysRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Displays", systemImage: "display.2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TV.secondaryText)
            if model.displays.isEmpty {
                Text("No displays detected")
                    .font(.system(size: 13))
                    .foregroundStyle(TV.tertiaryText)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Chip(title: "All", isSelected: configuration.wrappedValue.displayTarget == .all) {
                            configuration.wrappedValue.displayTarget = .all
                        }
                        if model.displays.count > 1 {
                            ForEach(model.displays) { display in
                                Chip(
                                    title: display.name + (display.isMain ? " · main" : ""),
                                    isSelected: configuration.wrappedValue.displayTarget.explicitDisplayID == display.id
                                ) {
                                    configuration.wrappedValue.displayTarget = .display(display.id)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder
    private var soundRow: some View {
        if item.kind == .video, destination != .screenSaver {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { !configuration.wrappedValue.muteVideo },
                    set: { configuration.wrappedValue.muteVideo = !$0 }
                )) {
                    Label("Sound", systemImage: "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TV.secondaryText)
                }
                .toggleStyle(.switch)
                .tint(.green)

                if !configuration.wrappedValue.muteVideo {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 11))
                        Slider(value: Binding(
                            get: { configuration.wrappedValue.volume },
                            set: { configuration.wrappedValue.volume = $0 }
                        ), in: 0...1)
                        .tint(.white)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 11))
                        Text("\(Int((configuration.wrappedValue.volume * 100).rounded()))%")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                    }
                    .foregroundStyle(TV.secondaryText)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.snappy(duration: 0.2), value: configuration.wrappedValue.muteVideo)
        } else {
            Label(
                destination == .screenSaver ? "The Screen Saver always runs muted" : "Images have no sound",
                systemImage: "speaker.slash.fill"
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(TV.tertiaryText)
        }
    }
}

private struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    Capsule().fill(isSelected ? Color.white : Color.white.opacity(isHovering ? 0.16 : 0.08))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
