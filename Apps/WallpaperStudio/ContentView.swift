import SwiftUI
import WallpaperCore

/// Root of the window: a dark full-bleed canvas, a floating tab bar,
/// the current page, and the wallpaper page presented over everything.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            TV.canvas.ignoresSafeArea()

            page
                .id(model.selectedSection)
                .transition(.opacity)

            if model.detailMediaItem == nil {
                TopBar(isSearchFocused: $isSearchFocused)
                    .transition(.opacity)
            }

            if let item = model.detailMediaItem {
                MediaDetailView(item: item)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.02)),
                        removal: .opacity
                    ))
                    .zIndex(10)
            }

            notifications
                .zIndex(20)
        }
        .animation(TV.pageSpring, value: model.selectedSection)
        .animation(TV.pageSpring, value: model.detailMediaID)
        .preferredColorScheme(.dark)
        .tint(.white)
        .sheet(isPresented: $model.isYouTubeSheetPresented) {
            YouTubeImportView()
                .environmentObject(model)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.importFiles(files)
            return true
        }
        .background {
            // ⌘F jumps to search from anywhere.
            Button("") {
                model.closeDetail()
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
        }
        .task(id: model.successMessage) {
            guard model.successMessage != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { model.successMessage = nil }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.selectedSection {
        case .home:
            if model.isLoading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.mediaItems.isEmpty {
                EmptyLibraryView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HomeView()
            }
        case .library:
            LibraryView()
        case .settings:
            SettingsView()
        }
    }

    private var notifications: some View {
        VStack(spacing: 10) {
            Spacer()
            ForEach(model.importJobs) { job in
                TVToast(
                    message: "\(job.title) — \(job.status)",
                    style: job.isFailed ? .error : .progress,
                    dismiss: job.isFailed ? { model.dismissImportJob(job.id) } : nil
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let message = model.bannerMessage {
                TVToast(message: message, style: .error) { model.dismissMessages() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let message = model.successMessage {
                TVToast(message: message, style: .success) { model.dismissMessages() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 26)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .animation(TV.pageSpring, value: model.importJobs.map(\.id))
        .animation(TV.pageSpring, value: model.bannerMessage)
        .animation(TV.pageSpring, value: model.successMessage)
        .allowsHitTesting(!model.importJobs.isEmpty || model.bannerMessage != nil || model.successMessage != nil)
    }
}

// MARK: - Top bar

/// Floating tab bar centered over the content.
private struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    var isSearchFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack {
            // Keeps the bar legible over bright artwork without a hard edge.
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            // Empty strip behind the controls moves the window (the title bar is hidden).
            Color.clear
                .frame(height: 58)
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            HStack(spacing: 14) {
                Spacer().frame(width: 64) // traffic lights

                Spacer(minLength: 0)

                HStack(spacing: 2) {
                    ForEach(AppSection.allCases) { section in
                        TabItem(section: section, isSelected: model.selectedSection == section) {
                            model.selectedSection = section
                        }
                    }
                }
                .padding(4)
                .tvGlassCapsule()

                Spacer(minLength: 0)

                SearchField(text: $model.searchText, isFocused: isSearchFocused) {
                    if model.selectedSection != .library { model.selectedSection = .library }
                }

                Button {
                    Task { await model.lockNowWithWallpaperStudio() }
                } label: {
                    Image(systemName: "lock.fill")
                }
                .buttonStyle(TVGlassButtonStyle(circle: true, height: 38))
                .disabled(model.isApplying)
                .help("Lock the screen with your wallpaper (⇧⌘L)")

                Button { model.chooseFiles() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(TVGlassButtonStyle(circle: true, height: 38))
                .help("Add images or videos (⌘O)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: 64, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }
}

private struct TabItem: View {
    let section: AppSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(section.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isSelected ? .black : (isHovering ? .white : TV.secondaryText))
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background {
                    if isSelected {
                        Capsule().fill(.white)
                    } else if isHovering {
                        Capsule().fill(Color.white.opacity(0.1))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.22), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let didStartTyping: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TV.secondaryText)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused(isFocused)
                .onChange(of: text) { _, new in
                    if !new.isEmpty { didStartTyping() }
                }
                .onSubmit(didStartTyping)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(TVQuietButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .frame(width: isFocused.wrappedValue || !text.isEmpty ? 220 : 150, height: 38)
        .tvGlassCapsule()
        .animation(TV.focusSpring, value: isFocused.wrappedValue)
    }
}
