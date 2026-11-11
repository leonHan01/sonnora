import Foundation
import Darwin
import AVFoundation
import Combine

// Self-contained assertions let Command Line Tools run the same core tests
// without depending on Xcode-only XCTest or compiler-macro plugins.
private var failures = 0
private func recordFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    failures += 1
    print("FAIL \(file):\(line): \(message)")
}
private func expect(_ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !condition() { recordFailure("Expectation failed", file: file, line: line) } }
    catch { recordFailure(String(describing: error), file: file, line: line) }
}
private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "SonoraTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Required value missing"]) }
    return value
}

// Nonblocking polling of a worker signal; never suspend the main thread.
private func consumeSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now()) == .success
}

final class PlaybackQueueTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testQueueDeduplicatesAndStartsAtRequestedSong() {
        let queue = PlaybackQueue(ids: [a, b, a, c], startingAt: b)
        expect(queue.ids == [a, b, c])
        expect(queue.currentID == b)
    }

    func testSequentialStopsAtEndWithoutLosingCurrentSong() {
        var queue = PlaybackQueue(ids: [a, b], startingAt: a)
        let outcome15 = queue.advance(mode: .sequential, automatic: true)
        expect(outcome15)
        expect(queue.currentID == b)
        let outcome17 = !(queue.advance(mode: .sequential, automatic: true))
        expect(outcome17)
        expect(queue.currentID == b)
    }

    func testSingleRepeatAffectsCompletionButNotManualNext() {
        var queue = PlaybackQueue(ids: [a, b], startingAt: a)
        let outcome23 = queue.advance(mode: .repeatOne, automatic: true)
        expect(outcome23)
        expect(queue.currentID == a)
        let outcome25 = queue.advance(mode: .repeatOne, automatic: false)
        expect(outcome25)
        expect(queue.currentID == b)
    }

    func testLoopWrapsInBothDirections() {
        var queue = PlaybackQueue(ids: [a, b], startingAt: b)
        let outcome31 = queue.advance(mode: .loopAll, automatic: true)
        expect(outcome31)
        expect(queue.currentID == a)
        let outcome33 = queue.retreat(mode: .loopAll)
        expect(outcome33)
        expect(queue.currentID == b)
    }

    func testPlayNextRepositionsExistingSongAndPreservesCursor() {
        var queue = PlaybackQueue(ids: [a, b, c, d], startingAt: c)
        queue.insertNext(a)
        expect(queue.ids == [b, c, a, d])
        expect(queue.currentID == c)
        queue.insertNext(c)
        expect(queue.ids == [b, c, a, d])
    }

    func testRemovingEarlierSongDoesNotChangeCurrentSong() {
        var queue = PlaybackQueue(ids: [a, b, c], startingAt: b)
        queue.remove([a])
        expect(queue.currentID == b)
        expect(queue.index == 0)
    }

    func testRemovingCurrentSongUsesFollowingSurvivor() {
        var queue = PlaybackQueue(ids: [a, b, c, d], startingAt: b)
        queue.remove([b, c])
        expect(queue.currentID == d)
        queue.remove([a, d])
        expect(queue.currentID == nil)
        expect(queue.index == nil)
    }

    func testShuffleKeepsHistoryAndAllUniqueItems() {
        var queue = PlaybackQueue(ids: [a, b, c, d], startingAt: b)
        queue.shuffleUpcoming()
        expect(Array(queue.ids.prefix(2)) == [a, b])
        expect(Set(queue.ids) == [a, b, c, d])
        expect(queue.currentID == b)
    }

    func testClearUpcomingRetainsCurrentAndHistory() {
        var queue = PlaybackQueue(ids: [a, b, c], startingAt: b)
        queue.clearUpcoming()
        expect(queue.ids == [a, b])
        expect(queue.currentID == b)
    }

    func testEmptyQueueOperationsAreSafe() {
        var queue = PlaybackQueue()
        let outcome79 = !(queue.advance(mode: .loopAll, automatic: true))
        expect(outcome79)
        let outcome80 = !(queue.retreat(mode: .loopAll))
        expect(outcome80)
        queue.select(999)
        queue.remove([a])
        queue.clearUpcoming()
        queue.shuffleUpcoming()
        expect(queue.currentID == nil)
        queue.insertNext(a)
        expect(queue.currentID == a)
    }
}

final class LibraryPersistenceTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    func testSnapshotRoundTripRetainsPlaylistFavoritesAndPosition() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var track = Track(url: URL(fileURLWithPath: "/tmp/a song.mp3"), title: "海边", artist: "Artist", album: "Album", duration: 123)
        track.isFavorite = true
        let playlist = Playlist(name: "夜晚", trackIDs: [track.id])
        let state = LibrarySnapshot(tracks: [track], playlists: [playlist], queue: PlaybackQueue(ids: [track.id]), mode: .repeatOne, volume: 0.3, elapsed: 32)
        let url = directory.appendingPathComponent("nested/library.json")
        try LibraryPersistence.save(state, to: url)
        expect(try LibraryPersistence.load(from: url) == state)
    }

    func testMissingLibraryStartsEmptyAndCorruptLibraryThrows() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        expect(try LibraryPersistence.load(from: url).tracks.isEmpty)
        try Data("broken".utf8).write(to: url)
        do { _ = try LibraryPersistence.load(from: url); recordFailure("Corrupt library must throw") }
        catch { /* expected */ }
        expect(try String(contentsOf: url) == "broken")
    }

    func testSanitizePrunesStaleReferencesAndInvalidVolume() {
        let track = Track(url: directory.appendingPathComponent("a.mp3"), title: "A", artist: "B", album: "C", duration: 5)
        let stale = UUID()
        let state = LibrarySnapshot(tracks: [track, track], playlists: [Playlist(name: "P", trackIDs: [stale, track.id, track.id])], queue: PlaybackQueue(ids: [stale, track.id]), volume: 5, elapsed: -1).sanitized()
        expect(state.tracks.count == 1)
        expect(state.playlists[0].trackIDs == [track.id])
        expect(state.queue.currentID == track.id)
        expect(state.volume == 1)
        expect(state.elapsed == 0)
    }
}

final class AudioImportTests {
    func testRealMP3MetadataAndNativeDecoder() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let track = try await TrackImporter.read(url)
        expect(track.title == "Silent Coast")
        expect(track.artist == "Sonora Test")
        expect(track.album == "Local Sessions")
        expect(track.duration > 11)
        expect(track.duration < 13)
        let player = try AVAudioPlayer(contentsOf: url)
        expect(player.numberOfChannels > 0)
        player.currentTime = 4
        expect(abs(player.currentTime - 4) < 0.1)
        let decodedFile = try AVAudioFile(forReading: url)
        let buffer = try require(AVAudioPCMBuffer(pcmFormat: decodedFile.processingFormat, frameCapacity: 1024))
        try decodedFile.read(into: buffer)
        expect(buffer.frameLength > 0)
        // Deliberately never call play(): the test makes no sound.
    }

    func testRecursiveDiscoveryDeduplicatesAndSkipsNonAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("album", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let song = nested.appendingPathComponent("song.MP3")
        try Data().write(to: song)
        try Data().write(to: nested.appendingPathComponent("notes.txt"))
        try Data().write(to: nested.appendingPathComponent(".hidden.mp3"))
        expect(TrackImporter.discover([root, song]).map(\.path) == [song.path])
    }

    func testCorruptAudioIsRejected() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("This is not audio".utf8).write(to: url)
        do { _ = try await TrackImporter.read(url); recordFailure("Corrupt MP3 must not enter the library") }
        catch { /* expected */ }
    }

    func testTimeFormattingHandlesHoursAndNonFiniteValues() {
        expect(clockText(3661) == "1:01:01")
        expect(clockText(-5) == "0:00")
        expect(clockText(.nan) == "0:00")
    }
}

@MainActor
final class TrackLocationTests {
    private func track(_ title: String, importedAt: Date = Date()) -> Track {
        Track(url: URL(fileURLWithPath: "/tmp/\(UUID()).mp3"), title: title, artist: "Artist", album: "Album", duration: 120, importedAt: importedAt)
    }

    private func model(with tracks: [Track]) -> PlayerModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        model.tracks = tracks
        return model
    }

    func testLocateEscapesExcludedFavoriteAndSearchWithoutChangingPlayback() {
        let current = track("Current")
        let other = track("Other")
        let model = model(with: [current, other])
        model.queue = PlaybackQueue(ids: [other.id, current.id], startingAt: current.id)
        model.section = .favorites
        model.search = "unrelated search"
        model.selectedTrackID = other.id
        model.sort = .artist
        model.mode = .shuffle
        model.elapsed = 42
        model.isPlaying = true
        let queue = model.queue

        model.locateCurrentTrack()

        expect(model.section == .all)
        expect(model.search.isEmpty)
        expect(model.selectedTrackID == current.id)
        expect(model.trackRevealRequest?.trackID == current.id)
        expect(model.visibleTracks.contains { $0.id == current.id })
        expect(model.queue == queue)
        expect(model.elapsed == 42)
        expect(model.isPlaying)
        expect(model.mode == .shuffle)
        expect(model.sort == .artist)
    }

    func testLocateKeepsPlaylistContainingCurrentSong() {
        let current = track("Current")
        let model = model(with: [current])
        let playlist = Playlist(name: "My playlist", trackIDs: [current.id])
        model.playlists = [playlist]
        model.section = .playlist(playlist.id)
        model.search = "no results"
        model.queue = PlaybackQueue(ids: [current.id])

        model.locateCurrentTrack()

        expect(model.section == .playlist(playlist.id))
        expect(model.visibleTracks.map(\.id) == [current.id])
        expect(model.selectedTrackID == current.id)
    }

    func testLocateFindsOlderSongOutsideRecentFifty() {
        let tracks = (0..<55).map { track("Song \($0)", importedAt: Date(timeIntervalSince1970: Double($0))) }
        let model = model(with: tracks)
        model.section = .recent
        model.queue = PlaybackQueue(ids: tracks.map(\.id), startingAt: tracks[0].id)
        expect(!model.visibleTracks.contains { $0.id == tracks[0].id })

        model.locateCurrentTrack()

        expect(model.section == .all)
        expect(model.visibleTracks.contains { $0.id == tracks[0].id })
        expect(model.trackRevealRequest?.trackID == tracks[0].id)
    }

    func testRepeatedLocateRequestsAreDistinctAndOldCompletionCannotConsumeNewOne() throws {
        let current = track("Current")
        let model = model(with: [current])
        model.queue = PlaybackQueue(ids: [current.id])
        model.selectedTrackID = current.id
        model.locateCurrentTrack()
        let first = try require(model.trackRevealRequest)
        model.locateCurrentTrack()
        let second = try require(model.trackRevealRequest)
        expect(first.id != second.id)
        expect(first.trackID == second.trackID)
        model.completeTrackReveal(first)
        expect(model.trackRevealRequest == second)
        model.completeTrackReveal(second)
        expect(model.trackRevealRequest == nil)
        model.locateCurrentTrack()
        expect(model.trackRevealRequest != nil)
    }

    func testLocateWithNoCurrentSongLeavesBrowsingStateAlone() {
        let other = track("Other")
        let model = model(with: [other])
        model.section = .favorites
        model.search = "my search"
        model.selectedTrackID = other.id
        model.locateCurrentTrack()
        expect(model.trackRevealRequest == nil)
        expect(model.search == "my search")
        expect(model.section == .favorites)
        expect(model.selectedTrackID == other.id)
        model.queue = PlaybackQueue(ids: [UUID()])
        model.locateCurrentTrack()
        expect(model.trackRevealRequest == nil)
        expect(model.search == "my search")
    }
}

@MainActor
final class PlaylistQuickAddTests {
    private func track(_ title: String) -> Track {
        Track(url: URL(fileURLWithPath: "/tmp/\(UUID()).mp3"), title: title, artist: "Artist", album: "Album", duration: 120)
    }

    private func model(with tracks: [Track]) -> PlayerModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        model.tracks = tracks
        return model
    }

    func testQuickAddPersistsSongAndKeepsPlaybackAndFavorite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        var song = track("Song")
        song.isFavorite = true
        model.tracks = [song]
        let playlist = Playlist(name: "Evening")
        model.playlists = [playlist]
        model.queue = PlaybackQueue(ids: [song.id])
        model.elapsed = 27
        model.isPlaying = true
        model.search = "Song"

        model.addToPlaylist(song.id, playlistID: playlist.id)

        expect(model.playlists[0].trackIDs == [song.id])
        expect(model.tracks[0].isFavorite)
        expect(model.queue.currentID == song.id)
        expect(model.elapsed == 27)
        expect(model.isPlaying)
        expect(model.search == "Song")
        model.persistNow()
        expect(try LibraryPersistence.load(from: url).playlists[0].trackIDs == [song.id])
    }

    func testQuickAddDoesNotDuplicateSong() {
        let song = track("Song")
        let model = model(with: [song])
        let playlist = Playlist(name: "Evening")
        model.playlists = [playlist]
        model.addToPlaylist(song.id, playlistID: playlist.id)
        model.addToPlaylist(song.id, playlistID: playlist.id)
        expect(model.playlists.count == 1)
        expect(model.playlists[0].trackIDs == [song.id])
    }

    func testCreateAndAddKeepsOriginalTargetAfterCurrentSongChanges() {
        let original = track("Original")
        let next = track("Next")
        let model = model(with: [original, next])
        model.playlistEditor = .createAdding(original.id)
        model.section = .favorites
        model.search = "Original"
        model.queue = PlaybackQueue(ids: [original.id, next.id], startingAt: next.id)

        model.savePlaylist(name: "  My playlist  ", editing: nil, adding: original.id)

        expect(model.playlists.count == 1)
        expect(model.playlists[0].name == "My playlist")
        expect(model.playlists[0].trackIDs == [original.id])
        expect(model.section == .favorites)
        expect(model.search == "Original")
        expect(model.queue.currentID == next.id)
        if case .none = model.playlistEditor {} else { recordFailure("Editor should close after saving") }
    }

    func testMissingSongAndBlankNameCannotCreateInvalidPlaylist() {
        let song = track("Song")
        let model = model(with: [song])
        model.playlistEditor = .createAdding(song.id)
        model.savePlaylist(name: "   ", editing: nil, adding: song.id)
        expect(model.playlists.isEmpty)
        if case .createAdding(let id) = model.playlistEditor { expect(id == song.id) }
        else { recordFailure("Blank name should leave editor open") }

        model.tracks = []
        model.savePlaylist(name: "Playlist", editing: nil, adding: song.id)
        expect(model.playlists.isEmpty)
        expect(model.notice?.isError == true)
        let list = Playlist(name: "Existing")
        model.playlists = [list]
        model.addToPlaylist(song.id, playlistID: list.id)
        expect(model.playlists[0].trackIDs.isEmpty)
    }

    func testNormalPlaylistCreationAndRenameStillWork() {
        let model = model(with: [])
        model.savePlaylist(name: "Original", editing: nil)
        expect(model.playlists.count == 1)
        let id = model.playlists[0].id
        expect(model.section == .playlist(id))
        expect(model.playlists[0].trackIDs.isEmpty)
        model.savePlaylist(name: "Renamed", editing: id)
        expect(model.playlists.count == 1)
        expect(model.playlists[0].id == id)
        expect(model.playlists[0].name == "Renamed")
    }
}

@MainActor
final class PlaybackUpdateIsolationTests {
    func testVolumeDragDoesNotInvalidateWholePage() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        var updates = 0
        var controlUpdates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        let controls = model.playbackVolume.objectWillChange.sink { controlUpdates += 1 }
        for step in 0..<100 { model.volume = Float(step) / 100 }
        expect(updates == 0)
        expect(controlUpdates == 100)
        expect(model.volume == 0.99)
        model.volume = 0.99
        expect(controlUpdates == 100)
        print("Volume drag: \(updates) whole-page notifications for 100 changes")
        withExtendedLifetime((observation, controls)) {}
    }

    func testSelectionDoesNotInvalidateWholePage() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        var updates = 0
        var listUpdates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        let selection = model.trackSelection.objectWillChange.sink { listUpdates += 1 }
        for _ in 0..<100 { model.selectedTrackID = UUID() }
        expect(updates == 0)
        expect(listUpdates == 100)
        expect(model.selectedTrackID != nil)
        let selectedID = model.selectedTrackID
        model.selectedTrackID = selectedID
        expect(listUpdates == 100)
        print("Selection: \(updates) whole-page notifications for 100 changes")
        withExtendedLifetime((observation, selection)) {}
    }

    func testIsolatedVolumeStillMutesClampsAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        model.volume = 0.35
        model.toggleMute()
        expect(model.volume == 0 && model.playbackVolume.value == 0)
        model.toggleMute()
        expect(model.volume == 0.35 && model.playbackVolume.value == 0.35)
        model.persistNow()
        let restored = PlayerModel(storageURL: url, enableSystemControls: false)
        expect(restored.playbackVolume.value == 0.35)
        restored.volume = 2
        expect(restored.volume == 1)
        restored.volume = -1
        expect(restored.volume == 0)
        restored.volume = .nan
        expect(restored.volume == 0.7)
        restored.persistNow()
    }

    func testProgressTicksDoNotInvalidateOpenLibraryMenus() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        var menuInvalidations = 0
        let observation = model.objectWillChange.sink { menuInvalidations += 1 }

        for step in 1...20 { model.elapsed = Double(step) * 0.25 }

        if menuInvalidations != 0 {
            recordFailure("20 playback-progress ticks invalidated library/menu views \(menuInvalidations) times")
        }
        withExtendedLifetime(observation) {}
    }

    func testProgressTicksStillRefreshTheTimeline() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        var timelineUpdates = 0
        let observation = model.playbackProgress.objectWillChange.sink { timelineUpdates += 1 }
        for step in 1...20 { model.elapsed = Double(step) * 0.25 }
        expect(timelineUpdates == 20)
        expect(model.playbackProgress.elapsed == 5)
        expect(model.elapsed == 5)
        withExtendedLifetime(observation) {}
    }
}

@MainActor
final class PlaybackStopTests {
    func testStopResetsDecoderAndPersistsPositionWithoutChangingQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let track = Track(url: URL(fileURLWithPath: CommandLine.arguments[1]), title: "Silent Coast", artist: "Sonora Test", album: "Local Sessions", duration: 12)
        let queue = PlaybackQueue(ids: [track.id])
        try LibraryPersistence.save(LibrarySnapshot(tracks: [track], queue: queue, elapsed: 5), to: url)
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        expect(abs(model.elapsed - 5) < 0.1)
        model.seek(to: 7)
        model.isMiniMode = true
        model.isPlaying = true

        model.stop()

        expect(!model.isPlaying)
        expect(model.elapsed == 0)
        expect(model.queue == queue)
        expect(model.currentTrack?.id == track.id)
        expect(model.playbackDuration > 11)
        expect(model.isMiniMode)
        // pause() reads the decoder clock, verifying it also reset, without playing audio.
        model.pause()
        expect(model.elapsed == 0)
        model.persistNow()
        let restored = try LibraryPersistence.load(from: url)
        expect(restored.elapsed == 0)
        expect(restored.queue == queue)
    }

    func testStopWithoutLoadedAudioIsSafeAndRepeatable() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        model.elapsed = 8
        model.stop()
        model.stop()
        expect(model.elapsed == 0)
        expect(!model.isPlaying)
        expect(model.currentTrack == nil)
        expect(model.queue.ids.isEmpty)
    }
}

@MainActor
final class PlayStatisticsTests {
    private func track(_ title: String, artist: String = "Artist", plays: Int = 0) -> Track {
        Track(url: URL(fileURLWithPath: "/tmp/\(UUID()).mp3"), title: title, artist: artist, album: "Album", duration: 120, playCount: plays)
    }

    private func model(with tracks: [Track]) -> PlayerModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        model.tracks = tracks
        return model
    }

    func testLegacyLibraryDefaultsCountsToZeroAndPreservesLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var song = track("Legacy")
        song.isFavorite = true
        song.artworkData = Data([1, 2, 3])
        let playlist = Playlist(name: "Favorites", trackIDs: [song.id])
        let snapshot = LibrarySnapshot(tracks: [song], playlists: [playlist], queue: PlaybackQueue(ids: [song.id]), elapsed: 32)
        var json = try require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var songs = try require(json["tracks"] as? [[String: Any]])
        songs[0].removeValue(forKey: "playCount")
        json["tracks"] = songs
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        expect(try LibraryPersistence.load(from: url) == snapshot)
    }

    func testSuccessfulStartCountsOnceAcrossPauseAndFailedResume() {
        let song = track("Song")
        let model = model(with: [song])
        model.queue = PlaybackQueue(ids: [song.id])
        // Simulate the decoder's start result without playing audio or opening a window.
        model.playbackDidStart(successfully: false)
        expect(model.tracks[0].playCount == 0)
        model.playbackDidStart(successfully: true)
        expect(model.tracks[0].playCount == 1)
        model.pause()
        model.playbackDidStart(successfully: false)
        model.playbackDidStart(successfully: true)
        model.playbackDidStart(successfully: true)
        expect(model.tracks[0].playCount == 1)
        expect(model.artists[0].playCount == 1)
        model.stop()
        model.playbackDidStart(successfully: true)
        expect(model.tracks[0].playCount == 2)
        expect(model.artists[0].playCount == 2)
    }

    func testTrackChangesAndRepeatOneStartNewCounts() {
        let a = track("A"), b = track("B")
        let model = model(with: [a, b])
        model.queue = PlaybackQueue(ids: [a.id, b.id])
        model.playbackDidStart(successfully: true)
        model.next()
        expect(model.tracks.map(\.playCount) == [1, 0]) // missing file cannot count
        model.playbackDidStart(successfully: true)
        expect(model.tracks.map(\.playCount) == [1, 1])
        model.mode = .repeatOne
        model.next(automatic: true)
        expect(model.queue.currentID == b.id)
        model.playbackDidStart(successfully: true)
        expect(model.tracks.map(\.playCount) == [1, 2])
        model.playTrack(a.id, in: [a.id, b.id])
        model.playbackDidStart(successfully: true)
        expect(model.tracks.map(\.playCount) == [2, 2])
        expect(model.artists[0].playCount == 4)
    }

    func testMissingAudioDoesNotIncreaseCounts() {
        let song = track("Missing", plays: 4)
        let model = model(with: [song])
        model.enqueueNext(song.id)
        expect(model.tracks[0].playCount == 4)
        model.playTrack(song.id)
        model.resume()
        expect(!model.isPlaying)
        expect(model.tracks[0].playCount == 4)
        expect(model.notice?.isError == true)
    }

    func testCountsPersistAndRestoringPausedAudioDoesNotCount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        var song = track("Persisted", plays: 8)
        song.url = URL(fileURLWithPath: CommandLine.arguments[1])
        try LibraryPersistence.save(LibrarySnapshot(tracks: [song], queue: PlaybackQueue(ids: [song.id]), elapsed: 3), to: url)
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        expect(!model.isPlaying)
        expect(model.tracks[0].playCount == 8)
        expect(abs(model.elapsed - 3) < 0.1)
        model.playbackDidStart(successfully: true)
        model.pause()
        model.persistNow()
        let restored = PlayerModel(storageURL: url, enableSystemControls: false)
        expect(restored.tracks[0].playCount == 9)
        expect(restored.artists[0].playCount == 9)
        expect(!restored.isPlaying)
    }

    func testArtistGroupingSearchAndStatisticsUseTheEntireLibrary() throws {
        let a = track("A", artist: "  Adele ", plays: 3)
        let b = track("B", artist: "adele", plays: 2)
        let c = track("C", artist: "周杰伦", plays: 7)
        let unknown = track("D", artist: " \n", plays: 1)
        let model = model(with: [a, b, c, unknown])
        model.section = .favorites
        model.search = "No song matches this"
        expect(model.artists.count == 3)
        let adele = try require(model.artists.first { $0.id == a.artistID })
        expect(adele.name == "Adele")
        expect(Set(adele.tracks.map(\.id)) == [a.id, b.id])
        expect(adele.playCount == 5)
        expect(model.artists.first { $0.id == unknown.artistID }?.name == "未知艺术家")
        model.search = "ADELE"
        expect(model.visibleArtists.map(\.id) == [a.artistID])
        model.search = "Song not present"
        expect(model.visibleArtists.isEmpty)
        model.search = "  "
        expect(model.visibleArtists.count == 3)
    }

    func testArtistNavigationClearsSearchAndKeepsPlaybackAndSongActions() {
        let a = track("A", artist: "Artist A", plays: 2)
        let b = track("B", artist: "Artist B", plays: 4)
        let model = model(with: [a, b])
        model.queue = PlaybackQueue(ids: [b.id, a.id])
        model.elapsed = 18
        model.isPlaying = true
        let queue = model.queue
        model.search = "Artist A"
        model.showArtist(a.artistID)
        expect(model.sectionTitle == "Artist A")
        expect(model.search.isEmpty)
        expect(model.visibleTracks.map(\.id) == [a.id])
        model.toggleFavorite(a.id)
        expect(model.visibleTracks[0].isFavorite)
        model.showArtists()
        expect(model.section == .artists)
        expect(model.search.isEmpty)
        expect(model.visibleArtists.count == 2)
        expect(model.queue == queue)
        expect(model.elapsed == 18)
        expect(model.isPlaying)
        model.locateCurrentTrack()
        expect(model.section == .all)
        expect(model.trackRevealRequest?.trackID == b.id)
        model.showArtist(b.artistID)
        model.locateCurrentTrack()
        expect(model.section == .artist(b.artistID))
    }

    func testArtistSongSortingAndRemovalRefreshStatistics() {
        let a = track("A", plays: 2), b = track("B", plays: 6)
        let c = track("C", artist: "Other", plays: 10)
        let model = model(with: [a, b, c])
        model.showArtist(a.artistID)
        model.sort = .playCount
        expect(model.visibleTracks.map(\.id) == [b.id, a.id])
        model.search = "A"
        expect(model.artists.first { $0.id == a.artistID }?.playCount == 8)
        model.search = ""
        model.removeFromLibrary(b.id)
        expect(model.visibleTracks.map(\.id) == [a.id])
        expect(model.artists.first { $0.id == a.artistID }?.playCount == 2)
        model.removeFromLibrary(a.id)
        expect(model.visibleTracks.isEmpty)
        expect(model.artists.map(\.id) == [c.artistID])
    }
}

@MainActor
final class PlaybackModeSelectionTests {
    func testDirectSelectionPreservesPlaybackAndPersistsMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        let songs = (0..<3).map { index in
            Track(url: URL(fileURLWithPath: "/tmp/sonora-mode-\(index).mp3"), title: "Song \(index)", artist: "Artist", album: "Album", duration: 120)
        }
        model.tracks = songs
        model.queue = PlaybackQueue(ids: songs.map(\.id), startingAt: songs[1].id)
        model.elapsed = 37
        model.isPlaying = true
        model.isMiniMode = true
        let originalQueue = model.queue

        model.setPlaybackMode(.repeatOne)
        expect(model.mode == .repeatOne)
        expect(model.queue == originalQueue)
        expect(model.elapsed == 37 && model.isPlaying && model.isMiniMode)
        model.persistNow()
        let saved = try LibraryPersistence.load(from: url)
        expect(saved.mode == .repeatOne)
        expect(saved.queue == originalQueue)
        expect(saved.elapsed == 37)

        model.setPlaybackMode(.sequential)
        expect(model.mode == .sequential)
        expect(model.queue == originalQueue)
        expect(model.elapsed == 37 && model.isPlaying && model.isMiniMode)
        model.persistNow()
        expect(try LibraryPersistence.load(from: url).mode == .sequential)
    }

    func testShuffleSelectionPreservesHistoryAndReselectionKeepsOrder() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        let ids = (0..<12).map { _ in UUID() }
        model.queue = PlaybackQueue(ids: ids, startingAt: ids[3])
        model.setPlaybackMode(.shuffle)
        expect(model.mode == .shuffle)
        expect(model.queue.currentID == ids[3])
        expect(Array(model.queue.ids.prefix(4)) == Array(ids.prefix(4)))
        expect(Set(model.queue.ids) == Set(ids))
        let shuffledQueue = model.queue
        model.setPlaybackMode(.shuffle)
        expect(model.queue == shuffledQueue)
        model.cycleMode()
        expect(model.mode == .sequential)
        expect(model.queue == shuffledQueue)
        model.cycleMode()
        expect(model.mode == .loopAll)
    }
}

@MainActor
final class PageDataTests {
    private func fixture() -> (PlayerModel, [Track]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let tracks = [
            Track(url: URL(fileURLWithPath: "/tmp/orchestra.mp3"), title: "Café 10", artist: " Alpha ", album: "Night", duration: 10, importedAt: Date(timeIntervalSince1970: 1), playCount: 1),
            Track(url: URL(fileURLWithPath: "/tmp/b.mp3"), title: "Song 2", artist: "Beta", album: "Day", duration: 20, importedAt: Date(timeIntervalSince1970: 2), playCount: 5),
            Track(url: URL(fileURLWithPath: "/tmp/c.mp3"), title: "Song 1", artist: "ALPHA", album: "Day", duration: 30, importedAt: Date(timeIntervalSince1970: 3), playCount: 2)
        ]
        let model = PlayerModel(storageURL: url, enableSystemControls: false)
        model.tracks = tracks
        return (model, tracks)
    }

    func testCachedPagesRefreshAfterFavoriteMetadataPlayCountAndRemoval() {
        let (model, tracks) = fixture()
        model.queue = PlaybackQueue(ids: [tracks[0].id, tracks[1].id])
        expect(model.currentTrack == tracks[0])
        expect(model.queuedTracks == Array(tracks.prefix(2)))
        expect(model.artists.count == 2)
        expect(model.libraryStatistics.playCount == 8)
        expect(model.sectionStatistics.duration == 60)
        model.section = .favorites
        expect(model.visibleTracks.isEmpty)
        model.toggleFavorite(tracks[0].id)
        expect(model.visibleTracks.map(\.id) == [tracks[0].id])
        expect(model.currentTrack?.isFavorite == true)
        expect(model.queuedTracks.first?.isFavorite == true)
        expect(model.libraryStatistics.favoriteCount == 1)

        model.tracks[0].title = "Updated"
        model.tracks[0].artist = "Beta"
        model.tracks[0].duration = 40
        model.section = .artist("alpha")
        expect(model.visibleTracks.map(\.id) == [tracks[2].id])
        expect(model.artists.first { $0.id == "beta" }?.tracks.count == 2)
        model.section = .all
        expect(model.sectionStatistics.duration == 90)
        expect(model.currentTrack?.title == "Updated")
        model.playbackDidStart(successfully: true) // Simulated start; no audio.
        expect(model.libraryStatistics.playCount == 9)
        expect(model.queuedTracks.first?.playCount == 2)
        expect(model.artists.first { $0.id == "beta" }?.playCount == 7)
        model.removeFromLibrary(tracks[1].id)
        expect(model.queuedTracks.map(\.id) == [tracks[0].id])
        expect(model.visibleTracks.count == 2)
        expect(model.libraryStatistics.playCount == 4)
        expect(model.track(for: tracks[1].id) == nil)
        model.tracks.append(tracks[1])
        expect(model.track(for: tracks[1].id) == tracks[1])
        expect(model.visibleTracks.count == 3)
    }

    func testCachedSearchAndSortPreserveMatchingAndPageOrder() {
        let (model, tracks) = fixture()
        expect(model.visibleTracks.map(\.id) == tracks.reversed().map(\.id))
        model.sort = .title
        expect(model.visibleTracks.map(\.id) == [tracks[0].id, tracks[2].id, tracks[1].id])
        model.search = "  CAFE  "
        expect(model.visibleTracks.map(\.id) == [tracks[0].id])
        model.search = "orchestra"
        expect(model.visibleTracks.map(\.id) == [tracks[0].id])
        model.search = "DAY"
        expect(model.visibleTracks.map(\.id) == [tracks[2].id, tracks[1].id])
        model.sort = .playCount
        expect(model.visibleTracks.map(\.id) == [tracks[1].id, tracks[2].id])
        model.section = .artist("alpha")
        expect(model.visibleTracks.map(\.id) == [tracks[2].id])
        model.search = ""
        expect(model.visibleTracks.map(\.id) == [tracks[2].id, tracks[0].id])
        model.sort = .artist
        expect(model.visibleTracks.count == 2)
        model.section = .recent
        model.sort = .added
        expect(model.visibleTracks.map(\.id) == tracks.reversed().map(\.id))
        // Exercise eviction as well as cached queries when revisiting a page.
        for index in 0..<20 {
            model.search = "missing \(index)"
            expect(model.visibleTracks.isEmpty)
        }
        model.search = ""
        expect(model.visibleTracks.map(\.id) == tracks.reversed().map(\.id))
    }

    func testCachedPlaylistReflectsReorderAdditionRenameAndDeletion() {
        let (model, tracks) = fixture()
        let list = Playlist(name: "First", trackIDs: [tracks[1].id, tracks[0].id])
        model.playlists = [list]
        model.section = .playlist(list.id)
        expect(model.visibleTracks.map(\.id) == list.trackIDs)
        model.addToPlaylist(tracks[2].id, playlistID: list.id)
        expect(model.visibleTracks.map(\.id) == list.trackIDs + [tracks[2].id])
        model.playlists[0].trackIDs.reverse()
        expect(model.visibleTracks.map(\.id) == [tracks[2].id, tracks[0].id, tracks[1].id])
        model.savePlaylist(name: "Renamed", editing: list.id)
        expect(model.sectionTitle == "Renamed")
        model.removeFromCurrentPlaylist(tracks[0].id)
        expect(model.sectionTracks.map(\.id) == [tracks[2].id, tracks[1].id])
        expect(model.sectionStatistics.duration == 50)
        model.deletePlaylist(list.id)
        expect(model.section == .all)
        expect(model.visibleTracks.count == 3)
        model.section = .playlist(list.id)
        expect(model.visibleTracks.isEmpty)
    }

    func testCachedArtistSortsAndQueueRespondToChanges() {
        let (model, tracks) = fixture()
        expect(model.sortedVisibleArtists(by: .name).map(\.id) == ["alpha", "beta"])
        expect(model.sortedVisibleArtists(by: .playCount).map(\.id) == ["beta", "alpha"])
        expect(model.sortedVisibleArtists(by: .trackCount).map(\.id) == ["alpha", "beta"])
        model.search = "BETA"
        expect(model.sortedVisibleArtists(by: .trackCount).map(\.id) == ["beta"])
        model.tracks[0].playCount = 30
        model.search = ""
        expect(model.sortedVisibleArtists(by: .playCount).map(\.id) == ["alpha", "beta"])
        model.queue = PlaybackQueue(ids: tracks.map(\.id))
        expect(model.queuedTracks.count == 3)
        model.queue.select(1)
        expect(model.currentTrack?.id == tracks[1].id)
        model.enqueueNext(tracks[0].id)
        expect(model.queuedTracks.map(\.id) == [tracks[1].id, tracks[0].id, tracks[2].id])
        model.clearUpcoming()
        expect(model.queuedTracks.map(\.id) == [tracks[1].id])
        model.queue = PlaybackQueue()
        expect(model.currentTrack == nil && model.queuedTracks.isEmpty)
    }

    func testNumberedRowsRetainIdentityAfterFilteringAndReordering() {
        let (_, tracks) = fixture()
        let rows = NumberedTracks(tracks: [tracks[2], tracks[0]])
        expect(rows.count == 2)
        expect(rows.map(\.id) == [tracks[2].id, tracks[0].id])
        expect(rows[1].index == 1 && rows[1].track == tracks[0])
        expect(rows.reversed().map(\.id) == [tracks[0].id, tracks[2].id])
        expect(NumberedTracks(tracks: []).isEmpty)
    }

    func testAutosaveRunsOffMainActorAndFinalFlushKeepsNewestState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let usedMainThread = DispatchSemaphore(value: 0)
        let writer = LibraryWriter { state, destination in
            if state.volume == 0.2 {
                if Thread.isMainThread { usedMainThread.signal() }
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
            try LibraryPersistence.save(state, to: destination)
        }
        let model = PlayerModel(storageURL: url, enableSystemControls: false, libraryWriter: writer)
        model.volume = 0.2
        // Waiting suspends this actor, allowing its debounced autosave to begin.
        // A slow disk writer must not prevent the actor from servicing this task.
        let start = Date()
        var didStart = false
        for _ in 0..<100 {
            if consumeSignal(entered) { didStart = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        expect(didStart)
        expect(Date().timeIntervalSince(start) < 2.5)
        expect(usedMainThread.wait(timeout: .now()) == .timedOut)
        expect(!FileManager.default.fileExists(atPath: url.path))
        model.volume = 0.8
        model.elapsed = 42
        release.signal()
        model.persistNow()
        let saved = try LibraryPersistence.load(from: url)
        expect(saved.volume == 0.8 && saved.elapsed == 42)
        try await Task.sleep(for: .milliseconds(50))
        expect(try LibraryPersistence.load(from: url) == saved)
    }

    func testBackgroundSaveFailureStillShowsNotice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blocker)
        let model = PlayerModel(storageURL: blocker.appendingPathComponent("library.json"), enableSystemControls: false)
        model.scheduleSave()
        for _ in 0..<100 {
            if model.notice?.isError == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        expect(model.notice?.isError == true)
        expect(model.notice?.message.contains("无法保存曲库") == true)
    }
}

@main
struct SonoraTestRunner {
    @MainActor
    static func main() async {
        var executed = 0
        func run(_ name: String, _ test: () async throws -> Void) async {
            let before = failures
            do { try await test() } catch { recordFailure("\(name): \(error)") }
            executed += 1
            print("\(before == failures ? "PASS" : "FAIL") \(name)")
        }
        await run("testQueueDeduplicatesAndStartsAtRequestedSong") { PlaybackQueueTests().testQueueDeduplicatesAndStartsAtRequestedSong() }
        await run("testSequentialStopsAtEndWithoutLosingCurrentSong") { PlaybackQueueTests().testSequentialStopsAtEndWithoutLosingCurrentSong() }
        await run("testSingleRepeatAffectsCompletionButNotManualNext") { PlaybackQueueTests().testSingleRepeatAffectsCompletionButNotManualNext() }
        await run("testLoopWrapsInBothDirections") { PlaybackQueueTests().testLoopWrapsInBothDirections() }
        await run("testPlayNextRepositionsExistingSongAndPreservesCursor") { PlaybackQueueTests().testPlayNextRepositionsExistingSongAndPreservesCursor() }
        await run("testRemovingEarlierSongDoesNotChangeCurrentSong") { PlaybackQueueTests().testRemovingEarlierSongDoesNotChangeCurrentSong() }
        await run("testRemovingCurrentSongUsesFollowingSurvivor") { PlaybackQueueTests().testRemovingCurrentSongUsesFollowingSurvivor() }
        await run("testShuffleKeepsHistoryAndAllUniqueItems") { PlaybackQueueTests().testShuffleKeepsHistoryAndAllUniqueItems() }
        await run("testClearUpcomingRetainsCurrentAndHistory") { PlaybackQueueTests().testClearUpcomingRetainsCurrentAndHistory() }
        await run("testEmptyQueueOperationsAreSafe") { PlaybackQueueTests().testEmptyQueueOperationsAreSafe() }
        await run("testSnapshotRoundTripRetainsPlaylistFavoritesAndPosition") { try LibraryPersistenceTests().testSnapshotRoundTripRetainsPlaylistFavoritesAndPosition() }
        await run("testMissingLibraryStartsEmptyAndCorruptLibraryThrows") { try LibraryPersistenceTests().testMissingLibraryStartsEmptyAndCorruptLibraryThrows() }
        await run("testSanitizePrunesStaleReferencesAndInvalidVolume") { LibraryPersistenceTests().testSanitizePrunesStaleReferencesAndInvalidVolume() }
        await run("testRealMP3MetadataAndNativeDecoder") { try await AudioImportTests().testRealMP3MetadataAndNativeDecoder() }
        await run("testRecursiveDiscoveryDeduplicatesAndSkipsNonAudio") { try AudioImportTests().testRecursiveDiscoveryDeduplicatesAndSkipsNonAudio() }
        await run("testCorruptAudioIsRejected") { try await AudioImportTests().testCorruptAudioIsRejected() }
        await run("testTimeFormattingHandlesHoursAndNonFiniteValues") { AudioImportTests().testTimeFormattingHandlesHoursAndNonFiniteValues() }
        await run("testLocateEscapesExcludedFavoriteAndSearchWithoutChangingPlayback") { TrackLocationTests().testLocateEscapesExcludedFavoriteAndSearchWithoutChangingPlayback() }
        await run("testLocateKeepsPlaylistContainingCurrentSong") { TrackLocationTests().testLocateKeepsPlaylistContainingCurrentSong() }
        await run("testLocateFindsOlderSongOutsideRecentFifty") { TrackLocationTests().testLocateFindsOlderSongOutsideRecentFifty() }
        await run("testRepeatedLocateRequestsAreDistinctAndOldCompletionCannotConsumeNewOne") { try TrackLocationTests().testRepeatedLocateRequestsAreDistinctAndOldCompletionCannotConsumeNewOne() }
        await run("testLocateWithNoCurrentSongLeavesBrowsingStateAlone") { TrackLocationTests().testLocateWithNoCurrentSongLeavesBrowsingStateAlone() }
        await run("testQuickAddPersistsSongAndKeepsPlaybackAndFavorite") { try PlaylistQuickAddTests().testQuickAddPersistsSongAndKeepsPlaybackAndFavorite() }
        await run("testQuickAddDoesNotDuplicateSong") { PlaylistQuickAddTests().testQuickAddDoesNotDuplicateSong() }
        await run("testCreateAndAddKeepsOriginalTargetAfterCurrentSongChanges") { PlaylistQuickAddTests().testCreateAndAddKeepsOriginalTargetAfterCurrentSongChanges() }
        await run("testMissingSongAndBlankNameCannotCreateInvalidPlaylist") { PlaylistQuickAddTests().testMissingSongAndBlankNameCannotCreateInvalidPlaylist() }
        await run("testNormalPlaylistCreationAndRenameStillWork") { PlaylistQuickAddTests().testNormalPlaylistCreationAndRenameStillWork() }
        await run("testProgressTicksDoNotInvalidateOpenLibraryMenus") { PlaybackUpdateIsolationTests().testProgressTicksDoNotInvalidateOpenLibraryMenus() }
        await run("testVolumeDragDoesNotInvalidateWholePage") { PlaybackUpdateIsolationTests().testVolumeDragDoesNotInvalidateWholePage() }
        await run("testSelectionDoesNotInvalidateWholePage") { PlaybackUpdateIsolationTests().testSelectionDoesNotInvalidateWholePage() }
        await run("testIsolatedVolumeStillMutesClampsAndPersists") { try PlaybackUpdateIsolationTests().testIsolatedVolumeStillMutesClampsAndPersists() }
        await run("testProgressTicksStillRefreshTheTimeline") { PlaybackUpdateIsolationTests().testProgressTicksStillRefreshTheTimeline() }
        await run("testStopResetsDecoderAndPersistsPositionWithoutChangingQueue") { try PlaybackStopTests().testStopResetsDecoderAndPersistsPositionWithoutChangingQueue() }
        await run("testStopWithoutLoadedAudioIsSafeAndRepeatable") { PlaybackStopTests().testStopWithoutLoadedAudioIsSafeAndRepeatable() }
        await run("testLegacyLibraryDefaultsCountsToZeroAndPreservesLibrary") { try PlayStatisticsTests().testLegacyLibraryDefaultsCountsToZeroAndPreservesLibrary() }
        await run("testSuccessfulStartCountsOnceAcrossPauseAndFailedResume") { PlayStatisticsTests().testSuccessfulStartCountsOnceAcrossPauseAndFailedResume() }
        await run("testTrackChangesAndRepeatOneStartNewCounts") { PlayStatisticsTests().testTrackChangesAndRepeatOneStartNewCounts() }
        await run("testMissingAudioDoesNotIncreaseCounts") { PlayStatisticsTests().testMissingAudioDoesNotIncreaseCounts() }
        await run("testCountsPersistAndRestoringPausedAudioDoesNotCount") { try PlayStatisticsTests().testCountsPersistAndRestoringPausedAudioDoesNotCount() }
        await run("testArtistGroupingSearchAndStatisticsUseTheEntireLibrary") { try PlayStatisticsTests().testArtistGroupingSearchAndStatisticsUseTheEntireLibrary() }
        await run("testArtistNavigationClearsSearchAndKeepsPlaybackAndSongActions") { PlayStatisticsTests().testArtistNavigationClearsSearchAndKeepsPlaybackAndSongActions() }
        await run("testArtistSongSortingAndRemovalRefreshStatistics") { PlayStatisticsTests().testArtistSongSortingAndRemovalRefreshStatistics() }
        await run("testDirectSelectionPreservesPlaybackAndPersistsMode") { try PlaybackModeSelectionTests().testDirectSelectionPreservesPlaybackAndPersistsMode() }
        await run("testShuffleSelectionPreservesHistoryAndReselectionKeepsOrder") { PlaybackModeSelectionTests().testShuffleSelectionPreservesHistoryAndReselectionKeepsOrder() }
        await run("testCachedPagesRefreshAfterFavoriteMetadataPlayCountAndRemoval") { PageDataTests().testCachedPagesRefreshAfterFavoriteMetadataPlayCountAndRemoval() }
        await run("testCachedSearchAndSortPreserveMatchingAndPageOrder") { PageDataTests().testCachedSearchAndSortPreserveMatchingAndPageOrder() }
        await run("testCachedPlaylistReflectsReorderAdditionRenameAndDeletion") { PageDataTests().testCachedPlaylistReflectsReorderAdditionRenameAndDeletion() }
        await run("testCachedArtistSortsAndQueueRespondToChanges") { PageDataTests().testCachedArtistSortsAndQueueRespondToChanges() }
        await run("testNumberedRowsRetainIdentityAfterFilteringAndReordering") { PageDataTests().testNumberedRowsRetainIdentityAfterFilteringAndReordering() }
        await run("testAutosaveRunsOffMainActorAndFinalFlushKeepsNewestState") { try await PageDataTests().testAutosaveRunsOffMainActorAndFinalFlushKeepsNewestState() }
        await run("testBackgroundSaveFailureStillShowsNotice") { try await PageDataTests().testBackgroundSaveFailureStillShowsNotice() }
        print("\(executed) tests, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
