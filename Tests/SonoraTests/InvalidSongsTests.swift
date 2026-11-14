import Foundation

private var failures = 0
private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { failures += 1; print("FAIL: \(message)") }
}

@main
struct InvalidSongsTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goodURL = root.appendingPathComponent("valid.mp3")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: goodURL)
        let badURL = root.appendingPathComponent("bad.mp3")
        try Data("not an audio file".utf8).write(to: badURL)
        func track(_ url: URL) -> Track { Track(url: url, title: url.lastPathComponent, artist: "artist", album: "album", duration: 30) }
        let good = track(goodURL), missing = track(root.appendingPathComponent("missing.mp3")), bad = track(badURL)
        let unavailable = track(root.appendingPathComponent("absent-volume/song.mp3"))
        let source = RemoteTrackSource(server: URL(string: "https://example.test")!, id: UUID(), sha256: String(repeating: "a", count: 64), size: 100)
        var linked = track(root.appendingPathComponent("linked.mp3")); linked.cloudSources = [source]; linked.isFavorite = true
        var remote = track(root.appendingPathComponent("cloud-only.mp3")); remote.remoteSource = source
        let validEvidence = await TrackImporter.invalidEvidence(for: good)
        let missingEvidence = await TrackImporter.invalidEvidence(for: missing)
        let badEvidence = await TrackImporter.invalidEvidence(for: bad)
        let unavailableEvidence = await TrackImporter.invalidEvidence(for: unavailable)
        let remoteEvidence = await TrackImporter.invalidEvidence(for: remote)
        expect(validEvidence == nil, "valid file is retained")
        expect(missingEvidence != nil, "missing local file is detected")
        expect(badEvidence != nil, "corrupt local audio is detected")
        expect(unavailableEvidence == nil, "unavailable parent directory is not treated as deletion")
        expect(remoteEvidence == nil, "uncached cloud songs are never removed")
        try Data("restored".utf8).write(to: missing.url)
        expect(missingEvidence?.stillMatches() == false, "a restored file invalidates old scan evidence")
        try FileManager.default.removeItem(at: missing.url)
        try Data("replaced audio bytes".utf8).write(to: badURL)
        expect(badEvidence?.stillMatches() == false, "a changed file invalidates old scan evidence")
        let model = PlayerModel(storageURL: root.appendingPathComponent("library.json"), enableSystemControls: false)
        model.tracks = [good, missing, bad, unavailable, linked, remote]
        let playlist = Playlist(name: "Test", trackIDs: model.tracks.map(\.id))
        model.playlists = [playlist]
        model.queue = PlaybackQueue(ids: [good.id, missing.id, linked.id])
        await model.checkInvalidSongs()
        expect(model.track(for: good.id) != nil && model.track(for: unavailable.id) != nil && model.track(for: remote.id) != nil, "valid, uncertain and cloud tracks are retained")
        expect(model.track(for: missing.id) == nil && model.track(for: bad.id) == nil, "invalid tracks removed")
        expect(model.track(for: linked.id)?.remoteSource == source && model.track(for: linked.id)?.isFavorite == true, "cloud copy and favorite preserved")
        expect(model.playlists[0].trackIDs == [good.id, unavailable.id, linked.id, remote.id], "playlist retains valid and linked tracks in order")
        expect(model.queue.ids == [good.id, linked.id], "queue removes invalid songs")
        expect(FileManager.default.fileExists(atPath: badURL.path), "original corrupt file is not deleted")
        model.persistNow()
        let reloaded = try LibraryPersistence.load(from: root.appendingPathComponent("library.json"))
        expect(reloaded.tracks.map(\.id) == [good.id, unavailable.id, linked.id, remote.id], "cleanup survives relaunch")
        print("Invalid song checks: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
