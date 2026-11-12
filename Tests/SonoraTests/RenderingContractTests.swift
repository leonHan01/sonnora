import SwiftUI
import ImageIO
import UniformTypeIdentifiers

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures += 1; print("FAIL: \(message)") }
}

// Checks the values and work boundaries consumed by the real views without
// constructing NSApplication, NSWindow, NSHostingView or playing audio.
@main
struct RenderingContractTests {
    @MainActor
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        defer {
            model.persistNow()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let tracks = (0..<5_000).map { index in
            Track(url: URL(fileURLWithPath: "/rendering/\(index).mp3"), title: "Song \(index)",
                  artist: "Artist", album: "Album", duration: 180)
        }
        model.tracks = tracks
        model.queue = PlaybackQueue(ids: tracks.map(\.id))
        model.selectedTrackID = tracks[0].id

        func rows() -> [TrackRow] {
            tracks.enumerated().map { index, track in
                TrackRow(model: model, track: track, number: index + 1, showAlbum: true,
                         current: model.queue.currentID == track.id, selected: model.selectedTrackID == track.id,
                         playing: model.queue.currentID == track.id && model.isPlaying, playlistID: nil)
            }
        }
        let initial = rows()
        model.volume = 0.2
        expect(initial == rows(), "Volume dragging must leave every row's render value unchanged")
        model.selectedTrackID = tracks[1].id
        let selected = rows()
        let selectionChanges = zip(initial, selected).filter { $0 != $1 }.count
        expect(selectionChanges == 2, "Only old/new selected row values should change")
        expect(model.trackRevealRequest == nil, "Ordinary selection must not request scrolling")
        model.isPlaying = true
        let playing = rows()
        expect(zip(selected, playing).filter { $0 != $1 }.count == 1, "Only the current row changes on resume")
        model.queue.select(2)
        expect(zip(playing, rows()).filter { $0 != $1 }.count == 2, "Switching songs changes only old/new current rows")
        model.locateCurrentTrack()
        expect(model.trackRevealRequest?.trackID == tracks[2].id, "Explicit locate must still request scrolling")
        print("PASS: 5,000 row values; volume changes 0, selection changes \(selectionChanges), playback changes 1")

        let original = initial[0]
        var edited = original
        edited.track.isFavorite.toggle()
        expect(original != edited, "Favorite must invalidate the row")
        edited = original
        edited.track.playCount += 1
        expect(original != edited, "Play count must invalidate the row")
        edited = original
        edited.track.artworkData = Data([1, 2, 3])
        expect(original != edited, "New artwork must invalidate the row")
        edited = original
        edited.playlistID = UUID()
        expect(original != edited, "Playlist actions must update when the context changes")
        edited = original
        edited.showAlbum = false
        expect(original != edited, "Album breakpoint must invalidate the row")
        edited = original
        edited.number = 42
        expect(original != edited, "Sorting must update row numbers")
        print("PASS: row content, actions and layout changes remain observable")

        let queueRow = QueueTrackRow(model: model, track: tracks[0], index: 0, current: false, playing: false)
        expect(queueRow == QueueTrackRow(model: model, track: tracks[0], index: 0, current: false, playing: false), "Unchanged queue row must compare equal")
        expect(queueRow != QueueTrackRow(model: model, track: tracks[0], index: 3, current: false, playing: false), "Queue reorder must update the button's target")
        expect(queueRow != QueueTrackRow(model: model, track: tracks[0], index: 0, current: true, playing: true), "Queue playback indicator must update")
        let page = LibraryPage(model: model, showAlbum: true)
        expect(page == LibraryPage(model: model, showAlbum: true), "Resize within the same layout must preserve the page value")
        expect(page != LibraryPage(model: model, showAlbum: false), "Crossing the breakpoint must change the page value")
        print("PASS: queue rows and page resize boundary")

        model.downloadProgress.begin(tracks[0])
        var pageUpdates = 0
        var progressUpdates = 0
        let pageSubscription = model.objectWillChange.sink { pageUpdates += 1 }
        let progressSubscription = model.downloadProgress.$active.dropFirst().sink { _ in progressUpdates += 1 }
        for received in 1...50 {
            model.downloadProgress.update(TrackDownloadProgress(receivedBytes: Int64(received), totalBytes: 100), for: tracks[0].id)
        }
        expect(pageUpdates == 0 && progressUpdates == 50, "download ticks must update only the progress views, not the library model")
        model.downloadProgress.update(TrackDownloadProgress(receivedBytes: 10, totalBytes: 100), for: tracks[0].id)
        model.downloadProgress.update(TrackDownloadProgress(receivedBytes: 90, totalBytes: 100), for: tracks[1].id)
        expect(model.downloadProgress.active?.progress.percentage == 50, "out-of-order and stale song progress must be ignored")
        model.downloadProgress.reset()
        expect(model.downloadProgress.active == nil, "cancelled download must clear its visible state")
        pageSubscription.cancel()
        progressSubscription.cancel()
        print("PASS: download progress isolation and stale-value guards")

        let mini = NSSize(width: 380, height: 124)
        let full = NSSize(width: 980, height: 700)
        let unlimited = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let miniConstraints = WindowSizeConstraints(minimum: mini, maximum: mini)
        let fullConstraints = WindowSizeConstraints(minimum: full, maximum: unlimited)
        expect(miniConstraints.changes(fromMinimum: mini, maximum: mini).isEmpty, "Steady mini updates must not rewrite constraints")
        expect(fullConstraints.changes(fromMinimum: full, maximum: unlimited).isEmpty, "Steady full updates must not rewrite constraints")
        expect(miniConstraints.changes(fromMinimum: full, maximum: unlimited) == [.minimum(mini), .maximum(mini)], "Enter mini: lower minimum before shrinking maximum")
        expect(fullConstraints.changes(fromMinimum: mini, maximum: mini) == [.maximum(unlimited), .minimum(full)], "Exit mini: expand maximum before raising minimum")
        expect(miniConstraints.changes(fromMinimum: mini, maximum: unlimited) == [.maximum(mini)], "Externally reset mini limits must still be repaired")
        let expanded = WindowSizeConstraints(minimum: NSSize(width: 1190, height: 700), maximum: unlimited)
        expect(expanded.changes(fromMinimum: full, maximum: unlimited).count == 1, "Opening queue should only update minimum width")
        print("PASS: idempotent window limits, mini/full order and repair")

        func png(width: Int, height: Int, red: CGFloat) throws -> Data {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.coderInvalidValue) }
            context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let data = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.coderInvalidValue) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.coderInvalidValue) }
            return data as Data
        }
        var cover = tracks[0]
        cover.artworkData = try png(width: 400, height: 400, red: 0.2)
        let request = ArtworkRequest(track: cover, pixelSize: 104)!
        let image = await ArtworkCache.loadThumbnail(for: request)
        expect(image?.width == 104 && image?.height == 104, "Cover must be decoded at the requested Retina size")
        expect(ArtworkCache.thumbnail(for: request) === image, "Decoded image should be reused")
        let repeated = await ArtworkCache.loadThumbnail(for: request)
        expect(repeated === image, "Repeated load must reuse the prepared pixels")
        cover.artworkData = try png(width: 400, height: 200, red: 0.9)
        let replacement = ArtworkRequest(track: cover, pixelSize: 104)!
        expect(ArtworkCache.thumbnail(for: replacement) == nil, "Replaced artwork must not return stale cached pixels")
        let wideImage = await ArtworkCache.loadThumbnail(for: replacement)
        expect(wideImage?.width == 208 && wideImage?.height == 104, "Nonsquare art needs enough pixels to fill the square")
        expect(ArtworkCache.thumbnail(for: request) == nil, "Cache entry must distinguish source data")
        print("PASS: background thumbnail size, cache reuse and replacement")

        var cancelledCover = cover
        cancelledCover.id = UUID()
        let cancelledRequest = ArtworkRequest(track: cancelledCover, pixelSize: 104)!
        let pending = Task { @MainActor in await ArtworkCache.loadThumbnail(for: cancelledRequest) }
        pending.cancel()
        let cancelled = await pending.value
        expect(cancelled == nil && ArtworkCache.thumbnail(for: cancelledRequest) == nil, "Cancelled offscreen work must not populate the cache")
        cover.artworkData = Data("not an image".utf8)
        let invalid = await ArtworkCache.loadThumbnail(for: ArtworkRequest(track: cover, pixelSize: 104)!)
        expect(invalid == nil, "Invalid artwork should use the placeholder")
        expect(ArtworkRequest(track: tracks[0], pixelSize: 104) == nil, "Missing artwork should use the placeholder")
        print("PASS: cancelled, missing and invalid artwork")

        print("7 rendering contract groups, \(failures) failures; no window created")
        if failures > 0 { exit(1) }
    }
}
