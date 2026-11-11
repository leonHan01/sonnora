import Foundation
import Darwin

// Exercises the data reads used by the real pages, without a window or audio.
@main
struct PagePerformanceTests {
    @MainActor
    static func main() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        model.tracks = (0..<5_000).map { index in
            Track(url: URL(fileURLWithPath: "/performance/song-\(index).mp3"),
                  title: "歌曲 Song \(5_000 - index)", artist: "歌手 Artist \(index % 200)",
                  album: "Album \(index % 100)", duration: Double(180 + index % 60),
                  importedAt: Date(timeIntervalSince1970: Double(index)),
                  isFavorite: index % 3 == 0, playCount: index % 20)
        }
        let playlist = Playlist(name: "大歌单", trackIDs: model.tracks.reversed().map(\.id))
        model.playlists = [playlist]
        model.queue = PlaybackQueue(ids: playlist.trackIDs)
        model.sort = .title
        var checksum = 0
        var failures = 0

        func measure(_ name: String, _ operation: () -> Void) {
            operation() // A page already on screen must not redo its work on every UI change.
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0..<8 {
                model.selectedTrackID = model.tracks[index].id
                model.showQueue = index.isMultiple(of: 2)
                operation()
            }
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print(String(format: "%@ (8 refreshes): %.3f ms", name, milliseconds))
            if milliseconds > 100 {
                print("FAIL: repeated page reads exceeded the 100 ms total budget")
                failures += 1
            }
        }

        measure("All songs") {
            for _ in 0..<6 { checksum += model.visibleTracks.count }
            checksum += model.sectionTracks.count + model.artists.count
        }
        model.section = .playlist(playlist.id)
        measure("Playlist") {
            for _ in 0..<6 { checksum += model.visibleTracks.count }
            checksum += model.sectionTracks.count
        }
        model.search = "Song 4"
        measure("Search results") {
            for _ in 0..<6 { checksum += model.visibleTracks.count }
        }
        model.section = .artists
        model.search = "Artist 1"
        measure("Artists") {
            for _ in 0..<4 { checksum += model.visibleArtists.count }
            checksum += model.artists.count
        }
        measure("Queue") {
            for _ in 0..<4 { checksum += model.queuedTracks.count }
            for _ in 0..<30 { checksum += model.currentTrack?.playCount ?? 0 }
        }
        print("Checksum: \(checksum); \(failures) performance failures")
        if failures > 0 { exit(1) }
    }
}
