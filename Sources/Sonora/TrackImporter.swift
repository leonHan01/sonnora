import AppKit
import AVFoundation

enum TrackImporter {
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]

    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func discover(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        let manager = FileManager.default
        func add(_ url: URL) {
            let canonical = canonicalURL(url)
            guard extensions.contains(canonical.pathExtension.lowercased()), seen.insert(canonical.path).inserted else { return }
            result.append(canonical)
        }
        for url in urls where url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            if directory.boolValue {
                if let files = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let file as URL in files {
                        if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { add(file) }
                    }
                }
            } else { add(url) }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func read(_ url: URL) async throws -> Track {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        var track = Track(url: url, title: url.deletingPathExtension().lastPathComponent, artist: "未知艺术家", album: "未知专辑", duration: duration)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        for item in metadata {
            switch item.commonKey {
            case .commonKeyTitle:
                if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { track.title = value }
            case .commonKeyArtist:
                if let value = try? await item.load(.stringValue), !value.isEmpty { track.artist = value }
            case .commonKeyAlbumName:
                if let value = try? await item.load(.stringValue), !value.isEmpty { track.album = value }
            case .commonKeyArtwork:
                if let data = try? await item.load(.dataValue) { track.artworkData = thumbnail(data) }
            default: break
            }
        }
        return track
    }

    private static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
