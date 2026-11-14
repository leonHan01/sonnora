import AppKit
import AVFoundation

struct InvalidTrackEvidence: Sendable {
    let id: UUID
    let url: URL
    let size: UInt64?
    let modified: Date?

    static func missing(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: parent.path) else { return false }
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return false }
        catch let error as NSError {
            return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
                || error.domain == NSPOSIXErrorDomain && error.code == ENOENT
        }
    }

    func stillMatches() -> Bool {
        guard let size, let modified else { return Self.missing(url) }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return (attrs[.size] as? NSNumber)?.uint64Value == size && (attrs[.modificationDate] as? Date) == modified
    }
}

enum TrackImporter {
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]

    static func invalidEvidence(for track: Track) async -> InvalidTrackEvidence? {
        guard track.remoteSource == nil, track.url.isFileURL else { return nil }
        let manager = FileManager.default
        guard let attrs = try? manager.attributesOfItem(atPath: track.url.path) else {
            return InvalidTrackEvidence.missing(track.url) ? InvalidTrackEvidence(id: track.id, url: track.url, size: nil, modified: nil) : nil
        }
        guard attrs[.type] as? FileAttributeType == .typeRegular, manager.isReadableFile(atPath: track.url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value, let modified = attrs[.modificationDate] as? Date else { return nil }
        let asset = AVURLAsset(url: track.url)
        guard let playable = try? await asset.load(.isPlayable), !playable else { return nil }
        return InvalidTrackEvidence(id: track.id, url: track.url, size: size, modified: modified)
    }

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
