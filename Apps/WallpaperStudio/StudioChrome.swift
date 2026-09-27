import AppKit
import SwiftUI
import WallpaperCore

// MARK: - Design tokens
//
// Wallpaper Studio's visual language follows the Apple TV app: a dark, full-bleed
// canvas where the artwork is the interface, large confident type, frosted glass for
// every control that floats over content, and a "focus" lift on whatever is under the
// pointer instead of borders and selection rings.

enum TV {
    static let canvas = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let raised = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.10)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.40)
    static let accent = Color.white

    static let pageInset: CGFloat = 56
    static let cardRadius: CGFloat = 14
    static let panelRadius: CGFloat = 24

    static let focusSpring = Animation.spring(response: 0.32, dampingFraction: 0.72)
    static let pageSpring = Animation.spring(response: 0.45, dampingFraction: 0.86)

    static func timeLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass on macOS 26, frosted material before it.
    @ViewBuilder
    func tvGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(TV.hairline, lineWidth: 1) }
        }
    }

    func tvGlassCapsule(interactive: Bool = false) -> some View {
        tvGlass(in: Capsule(), interactive: interactive)
    }
}

// MARK: - Buttons

/// The white pill used for the one primary action on a screen ("Aplică", "Setează").
struct TVPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 26)
            .frame(height: 46)
            .background(.white, in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .animation(TV.focusSpring, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Frosted secondary action; `circle` for icon-only buttons.
struct TVGlassButtonStyle: ButtonStyle {
    var circle = false
    var height: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, circle: circle, height: height)
    }

    private struct GlassButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let circle: Bool
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            Group {
                if circle {
                    configuration.label
                        .frame(width: height, height: height)
                        .tvGlass(in: Circle(), interactive: true)
                } else {
                    configuration.label
                        .padding(.horizontal, 22)
                        .frame(height: height)
                        .tvGlassCapsule(interactive: true)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1 : 0.4)
            .brightness(isHovering ? 0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.95 : (isHovering ? 1.04 : 1))
            .animation(TV.focusSpring, value: configuration.isPressed)
            .animation(TV.focusSpring, value: isHovering)
            .onHover { isHovering = $0 }
            .contentShape(circle ? AnyShape(Circle()) : AnyShape(Capsule()))
        }
    }
}

/// Plain text-like button that brightens on hover (tab bar, "Vezi tot").
struct TVQuietButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration, isActive: isActive)
    }

    private struct QuietBody: View {
        let configuration: ButtonStyleConfiguration
        let isActive: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isActive || isHovering ? TV.primaryText : TV.secondaryText)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .onHover { isHovering = $0 }
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Focus lift

/// tvOS-style focus: the element under the pointer grows, casts a deeper shadow,
/// tilts slightly toward the pointer and catches a specular highlight.
struct TVFocusEffect: ViewModifier {
    var cornerRadius: CGFloat = TV.cardRadius
    var scale: CGFloat = 1.07
    var isFocused: Bool
    @State private var pointer: CGPoint?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let tilt = tiltAngles
        return content
            .overlay {
                // Specular sheen that follows the pointer.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(isFocused ? 0.22 : 0), .clear],
                            center: sheenCenter,
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 0.75
                        )
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                GeometryReader { proxy in
                    Color.clear.onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, new in size = new }
                }
            }
            .rotation3DEffect(.degrees(tilt.x), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.y), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .scaleEffect(isFocused ? scale : 1)
            .shadow(color: .black.opacity(isFocused ? 0.55 : 0.25), radius: isFocused ? 26 : 8, y: isFocused ? 18 : 4)
            .zIndex(isFocused ? 1 : 0)
            .animation(TV.focusSpring, value: isFocused)
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: pointer)
            .onContinuousHover { phase in
                switch phase {
                case let .active(location): pointer = location
                case .ended: pointer = nil
                }
            }
    }

    private var sheenCenter: UnitPoint {
        guard let pointer, size.width > 0, size.height > 0 else { return .top }
        return UnitPoint(x: pointer.x / size.width, y: pointer.y / size.height)
    }

    private var tiltAngles: (x: Double, y: Double) {
        guard isFocused, let pointer, size.width > 0, size.height > 0 else { return (0, 0) }
        let dx = (pointer.x / size.width - 0.5) * 2
        let dy = (pointer.y / size.height - 0.5) * 2
        return (x: Double(-dy) * 4, y: Double(dx) * 5)
    }
}

extension View {
    func tvFocus(_ isFocused: Bool, cornerRadius: CGFloat = TV.cardRadius, scale: CGFloat = 1.07) -> some View {
        modifier(TVFocusEffect(cornerRadius: cornerRadius, scale: scale, isFocused: isFocused))
    }
}

// MARK: - Artwork

/// Loads thumbnails/posters off the main thread and caches them.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSURL, NSImage>()

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        // Read the bytes off the main actor; only the (lazy) NSImage wrapper is built here.
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct ArtworkImage: View {
    let url: URL?
    var symbol = "photo"
    @State private var image: NSImage?

    init(url: URL?, symbol: String = "photo") {
        self.url = url
        self.symbol = symbol
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                startPoint: .top,
                endPoint: .bottom
            )
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(TV.tertiaryText)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ArtworkCache.shared.cached(url) { image = hit; return }
            let loaded = await ArtworkCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
}

// MARK: - Small components

struct TVShelfHeader: View {
    let title: String
    var subtitle: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(TV.primaryText)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TV.tertiaryText)
            }
            Spacer(minLength: 0)
            if let action {
                Button(action: action.run) {
                    HStack(spacing: 4) {
                        Text(action.title)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(TVQuietButtonStyle())
            }
        }
    }
}

/// Compact metadata badge, like "4K" or "HDR" on Apple TV.
struct TVBadge: View {
    let text: String
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(filled ? .black : TV.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(filled ? Color.white.opacity(0.85) : .clear)
            }
            .overlay {
                if !filled {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(TV.secondaryText.opacity(0.7), lineWidth: 1)
                }
            }
    }
}

struct TVToast: View {
    enum Style { case error, success, progress }

    let message: String
    let style: Style
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            switch style {
            case .progress:
                ProgressView().controlSize(.small).tint(.white)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TV.primaryText)
                .lineLimit(3)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(TVQuietButtonStyle())
                .accessibilityLabel("Închide mesajul")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .tvGlassCapsule()
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .frame(maxWidth: 640)
    }
}

// MARK: - Destination metadata

extension WallpaperDestination {
    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .screenSaver: "Screen Saver"
        case .lockScreen: "Lock Screen"
        }
    }

    var symbol: String {
        switch self {
        case .desktop: "desktopcomputer"
        case .screenSaver: "sparkles.tv"
        case .lockScreen: "lock.fill"
        }
    }

    var applyTitle: String {
        switch self {
        case .desktop: "Setează pe Desktop"
        case .screenSaver: "Setează ca Screen Saver"
        case .lockScreen: "Setează pe Lock Screen"
        }
    }
}

extension MediaItem {
    var badges: [String] {
        var values: [String] = []
        let longest = max(pixelSize.width, pixelSize.height)
        if longest >= 7680 { values.append("8K") }
        else if longest >= 3840 { values.append("4K") }
        else if longest >= 1920 { values.append("HD") }
        if let codec, !codec.isEmpty { values.append(codec.uppercased()) }
        return values
    }

    var kindLabel: String { kind == .video ? "Video" : "Imagine" }

    var isFromYouTube: Bool {
        if case .youtube = origin { return true }
        return false
    }

    var metaLine: String {
        var parts = [kindLabel]
        if let duration { parts.append(TV.timeLabel(duration)) }
        parts.append("\(pixelSize.width)×\(pixelSize.height)")
        if case let .youtube(_, _, channel) = origin, let channel { parts.append(channel) }
        return parts.joined(separator: " · ")
    }
}
