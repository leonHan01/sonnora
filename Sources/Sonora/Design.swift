import SwiftUI
import ImageIO

// Use the property-wrapper type explicitly: newer SDKs also export a State macro
// whose compiler plugin is not bundled with standalone Command Line Tools.
typealias LocalState<Value> = SwiftUI.State<Value>

struct ArtworkRequest: Equatable, Sendable {
    // The radio's large cover needs Retina pixels; small list rows stay small.
    static let maximumPixelSize = 1_024
    let trackID: UUID
    let data: Data
    let pixelSize: Int

    init?(track: Track?, pixelSize: Int) {
        guard let track, let data = track.artworkData else { return nil }
        trackID = track.id
        self.data = data
        self.pixelSize = max(1, min(Self.maximumPixelSize, pixelSize))
    }

    var cacheKey: NSString { "\(trackID.uuidString)-\(pixelSize)" as NSString }
}

// One decoder bounds CPU pressure while rapidly scrolling through new covers.
// ImageIO prepares pixels here, instead of deferring JPEG decode to drawing.
private actor ArtworkDecoder {
    static let shared = ArtworkDecoder()

    func decode(_ request: ArtworkRequest) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(request.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1
        // Keep enough pixels for scaledToFill, including nonsquare cover art.
        let maximum = min(Double(ArtworkRequest.maximumPixelSize), ceil(Double(request.pixelSize) * max(width, height) / max(1, min(width, height))))
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maximum),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

@MainActor
enum ArtworkCache {
    private final class Thumbnail: NSObject {
        let request: ArtworkRequest
        let image: CGImage
        init(request: ArtworkRequest, image: CGImage) {
            self.request = request
            self.image = image
        }
    }

    private static let thumbnails: NSCache<NSString, Thumbnail> = {
        let cache = NSCache<NSString, Thumbnail>()
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    static func thumbnail(for request: ArtworkRequest) -> CGImage? {
        guard let cached = thumbnails.object(forKey: request.cacheKey), cached.request == request else { return nil }
        return cached.image
    }

    static func loadThumbnail(for request: ArtworkRequest) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = thumbnail(for: request) { return cached }
        let work = Task.detached(priority: .userInitiated) { await ArtworkDecoder.shared.decode(request) }
        let image = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, let image else { return nil }
        thumbnails.setObject(Thumbnail(request: request, image: image), forKey: request.cacheKey,
                             cost: image.bytesPerRow * image.height)
        return image
    }

    // System Now Playing artwork is requested only when the song changes.
    private static let cache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 150
        return cache
    }()
    static func clear() { thumbnails.removeAllObjects(); cache.removeAllObjects() }

    static func image(for track: Track?) -> NSImage? {
        guard let track, let data = track.artworkData else { return nil }
        let key = track.id as NSUUID
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

enum Theme {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.080)
    static let sidebar = Color(red: 0.070, green: 0.080, blue: 0.095)
    static let surface = Color(red: 0.095, green: 0.108, blue: 0.125)
    static let raised = Color(red: 0.130, green: 0.145, blue: 0.164)
    static let accent = Color(red: 0.77, green: 0.94, blue: 0.43)
    static let text = Color(red: 0.94, green: 0.95, blue: 0.93)
    static let secondary = Color(red: 0.53, green: 0.57, blue: 0.59)
    static let line = Color.white.opacity(0.065)
}

struct AccentButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, compact ? 15 : 21)
            .padding(.vertical, compact ? 10 : 13)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text.opacity(configuration.isPressed ? 0.5 : 0.9))
            .padding(.horizontal, 17).padding(.vertical, 12)
            .background(Color.white.opacity(configuration.isPressed ? 0.09 : 0.045), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line))
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var color: Color = Theme.secondary
    var size: CGFloat = 15
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

struct ArtworkView: View {
    var track: Track?
    var size: CGFloat
    var radius: CGFloat = 10
    @Environment(\.displayScale) private var displayScale
    @LocalState private var loadedRequest: ArtworkRequest?
    @LocalState private var loadedImage: CGImage?

    var body: some View {
        let request = ArtworkRequest(track: track, pixelSize: Int(ceil(size * displayScale)))
        let image = loadedRequest == request ? loadedImage : request.flatMap { ArtworkCache.thumbnail(for: $0) }
        Group {
            if let image {
                Image(decorative: image, scale: displayScale).resizable().scaledToFill()
            } else {
                Theme.raised
            }
        }
        .frame(width: size, height: size).clipped()
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .accessibilityHidden(true)
        .task(id: request) {
            guard let request else {
                loadedRequest = nil
                loadedImage = nil
                return
            }
            let image = await ArtworkCache.loadThumbnail(for: request)
            guard !Task.isCancelled else { return }
            loadedImage = image
            loadedRequest = request
        }
        .onDisappear {
            // Lazy stacks retain row state. Keep offscreen pixels in the bounded
            // cache rather than retaining every cover visited during a scroll.
            loadedImage = nil
            loadedRequest = nil
        }
    }
}

struct AmbientRecord: View {
    var size: CGFloat = 230
    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.08)).blur(radius: 28).padding(-8)
            Circle().fill(LinearGradient(colors: [Color(red: 0.22, green: 0.27, blue: 0.22), Color(red: 0.075, green: 0.10, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
            ForEach(0..<14) { ring in
                Circle().stroke(.white.opacity(ring % 3 == 0 ? 0.10 : 0.035), lineWidth: 1)
                    .padding(CGFloat(ring) * size * 0.023 + 6)
            }
            Circle().fill(Theme.accent).frame(width: size * 0.31, height: size * 0.31)
            Image(systemName: "waveform").font(.system(size: size * 0.13, weight: .medium)).foregroundStyle(Theme.background)
            Circle().fill(Theme.background).frame(width: 5, height: 5).offset(y: size * 0.105)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(-18))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 15)
        .accessibilityHidden(true)
    }
}
