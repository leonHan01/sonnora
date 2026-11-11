import Foundation
import CryptoKit
import Darwin

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var respond: (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }
    static var delay: (URLRequest) -> TimeInterval = { _ in 0 }
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delay = Self.delay(request)
        if delay > 0 {
            let work = DispatchWorkItem { [weak self] in self?.deliver() }
            pending = work
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        } else { deliver() }
    }
    private func deliver() {
        do {
            let (code, data) = try Self.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { pending?.cancel() }
}

@main
struct OnlineLibraryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sonora-online-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { failures += 1; print("FAIL: \(message)") }
        }
        for address in ["https://example.test/", "http://127.0.0.1:8080", "http://localhost:8080"] {
            expect((try? OnlineSettings.serverURL(address)) != nil, "valid server \(address)")
        }
        for address in ["http://example.test", "https://user:secret@example.test", "https://example.test?token=x", "file:///tmp/music", "https://example.test/api"] {
            expect((try? OnlineSettings.serverURL(address)) == nil, "reject unsafe server")
        }
        let server = try OnlineSettings.serverURL("https://example.test")
        let record = ServerTrack(id: UUID(), title: "Online", artist: "Artist", album: "Album", duration: 12,
                                 extension: "mp3", sha256: String(repeating: "a", count: 64), size: 12, uploadedAt: "2026-11-11T01:02:03.123Z")
        let song = try record.track(server: server, cacheRoot: root.appendingPathComponent("cache"))
        let repeated = try record.track(server: server, cacheRoot: root.appendingPathComponent("cache"))
        let other = try record.track(server: URL(string: "https://other.test")!, cacheRoot: root)
        expect(song.id == repeated.id && song.id != other.id, "stable IDs scoped to server")
        expect(song.url.isFileURL && song.url.pathExtension == "mp3", "local cache path preserves audio extension")
        expect(song.importedAt.timeIntervalSince1970 > 0, "fractional server date")
        let data = try JSONEncoder().encode(song)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        expect(decoded == song, "remote metadata persists")
        var legacyJSON = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacyJSON.removeValue(forKey: "remoteSource")
        let legacy = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        expect(legacy.remoteSource == nil, "old library remains compatible")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = OnlineMusicClient(session: URLSession(configuration: configuration))
        let model = PlayerModel(storageURL: root.appendingPathComponent("library.json"), enableSystemControls: false, musicClient: client)
        let local = Track(url: root.appendingPathComponent("local.mp3"), title: "Local", artist: "Local", album: "Local", duration: 3)
        model.tracks = [local]
        var editedSong = song
        editedSong.isFavorite = true
        editedSong.playCount = 7
        model.tracks.append(editedSong)
        model.mergeOnlineTracks([song])
        expect(model.track(for: song.id)?.isFavorite == true && model.track(for: song.id)?.playCount == 7, "sync preserves favorites and counts")
        expect(model.availableTracks.map(\.id) == [local.id], "uncached online songs hidden offline")
        try FileManager.default.createDirectory(at: song.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: song.url)
        model.useOfflineMode(message: "test offline")
        expect(Set(model.availableTracks.map(\.id)) == Set([local.id, song.id]), "cached songs stay available offline")
        model.mergeOnlineTracks([])
        model.useOfflineMode(message: "test offline")
        expect(model.availableTracks.contains(where: { $0.id == song.id }), "server deletion keeps downloaded offline copy")
        try FileManager.default.removeItem(at: song.url)
        model.useOfflineMode(message: "test offline")
        expect(model.availableTracks.map(\.id) == [local.id], "lost cache removed from available library")

        StubProtocol.respond = { request in
            guard request.url?.path == "/api/music/tracks", request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" else {
                throw URLError(.badServerResponse)
            }
            return (200, Data("[]".utf8))
        }
        let records = try await client.list(server: server, token: "test-token")
        expect(records.isEmpty, "authenticated empty online library is successful")
        StubProtocol.respond = { _ in (401, Data()) }
        do { _ = try await client.list(server: server, token: "bad"); expect(false, "401 throws") }
        catch { expect(error.localizedDescription.contains("认证"), "authentication error is actionable") }
        StubProtocol.respond = { _ in throw URLError(.timedOut) }
        model.reconnect()
        for _ in 0..<100 where model.isConnecting { try await Task.sleep(for: .milliseconds(10)) }
        expect(!model.isOnline && !model.isConnecting, "timeout switches to offline")
        expect(model.availableTracks.map(\.id) == [local.id], "local music survives failed server")
        StubProtocol.respond = { _ in (200, Data("[]".utf8)) }
        model.reconnect()
        for _ in 0..<100 where model.isConnecting { try await Task.sleep(for: .milliseconds(10)) }
        expect(model.isOnline && !model.isConnecting, "retry recovers after server returns")
        expect(model.availableTracks.contains(where: { $0.id == local.id }), "local music remains online")
        let bytes = Data("downloaded audio fixture".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var download = song
        download.remoteSource = RemoteTrackSource(server: server, id: record.id, sha256: hash, size: Int64(bytes.count))
        StubProtocol.respond = { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" else { return (401, Data()) }
            return (200, bytes)
        }
        try await client.download(download, token: "test-token")
        let cached = try Data(contentsOf: download.url)
        expect(cached == bytes, "download verifies hash and saves offline cache")
        try FileManager.default.removeItem(at: download.url)
        StubProtocol.respond = { _ in (200, Data("corrupt".utf8)) }
        do { try await client.download(download, token: "test-token"); expect(false, "corrupt download throws") }
        catch { expect(!FileManager.default.fileExists(atPath: download.url.path), "corrupt download never becomes cache") }

        func radioPayload(id: UUID) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "title": "Radio", "artist": "Artist", "album": "Album",
                                                       "duration": 12, "extension": "mp3", "sha256": String(repeating: "a", count: 64),
                                                       "size": 12, "uploadedAt": "2026-11-12T00:00:00Z"])
        }
        let firstPayload = try radioPayload(id: record.id)
        StubProtocol.respond = { request in
            guard request.url?.path == "/api/music/tracks/radio",
                  URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == record.id.uuidString.lowercased(),
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer radio-token" else { throw URLError(.badURL) }
            return (200, firstPayload)
        }
        let selection = try await client.radio(server: server, token: "radio-token", excluding: record.id)
        expect(selection?.id == record.id, "radio requests exactly one song with authentication and previous-song exclusion")
        StubProtocol.respond = { _ in (204, Data()) }
        let empty = try await client.radio(server: server, token: "", excluding: nil)
        expect(empty == nil, "empty server radio does not decode an empty body")

        func settle(_ ready: () -> Bool) async throws {
            for _ in 0..<100 {
                if ready() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            expect(false, "radio request completes within test deadline")
        }
        // Intentionally invalid local files check selection without audio playback.
        try Data("not audio".utf8).write(to: local.url)
        let radioModel = PlayerModel(storageURL: root.appendingPathComponent("radio/library.json"), enableSystemControls: false, musicClient: client)
        radioModel.tracks = [local]
        StubProtocol.delay = { $0.url?.path.hasSuffix("/audio") == true ? 0.5 : 0 }
        StubProtocol.respond = { _ in (200, firstPayload) }
        radioModel.showRadio()
        try await settle { radioModel.radioTrackID != nil && !radioModel.isRadioLoading }
        let firstRadioID = radioModel.radioTrackID
        expect(radioModel.section == .radio && radioModel.isRadioActive, "sidebar starts the radio")
        expect(radioModel.queue.ids == [firstRadioID!], "radio uses a single-song queue")
        expect(radioModel.isRadioBuffering, "first radio song buffers before playback")
        radioModel.pause()
        expect(!radioModel.isRadioBuffering && radioModel.isRadioActive, "pause cancels a pending radio download")
        expect(radioModel.radioMessage.contains("暂停"), "cancelled buffering no longer shows a loading message")
        radioModel.nextRadioTrack()
        try await settle { !radioModel.isRadioLoading && radioModel.loadingTrackID != nil }
        StubProtocol.respond = { _ in throw URLError(.timedOut) }
        radioModel.reconnect()
        try await settle { !radioModel.isConnecting }
        expect(!radioModel.isOnline && radioModel.currentTrack?.id == local.id, "catalog disconnection during buffering continues with offline radio")
        radioModel.stop()
        StubProtocol.respond = { request in
            (200, request.url?.path.hasSuffix("/radio") == true ? firstPayload : Data("[]".utf8))
        }
        radioModel.reconnect()
        try await settle { !radioModel.isConnecting }
        radioModel.nextRadioTrack()
        try await settle { !radioModel.isRadioLoading && radioModel.radioTrackID == firstRadioID }
        radioModel.pause()
        let secondID = UUID()
        let secondPayload = try radioPayload(id: secondID)
        StubProtocol.respond = { request in
            if request.url?.path.hasSuffix("/radio") == true {
                guard URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == record.id.uuidString.lowercased() else {
                    throw URLError(.badURL)
                }
            }
            return (200, secondPayload)
        }
        radioModel.setPlaybackMode(.repeatOne)
        radioModel.next(automatic: true)
        try await settle { radioModel.radioTrackID != firstRadioID && !radioModel.isRadioLoading }
        expect(radioModel.radioTrack?.remoteSource?.id == secondID, "completion fetches a new server song even in repeat-one mode")
        expect(radioModel.queue.ids.count == 1, "switching does not grow the queue")
        radioModel.stop()
        expect(!radioModel.isPlaying && !radioModel.isRadioBuffering, "stop cancels radio buffering")

        StubProtocol.delay = { _ in 0.15 }
        radioModel.nextRadioTrack()
        radioModel.playTrack(local.id, in: [local.id])
        try await Task.sleep(for: .milliseconds(220))
        expect(!radioModel.isRadioActive && radioModel.currentTrack?.id == local.id, "late radio responses cannot replace ordinary playback")
        StubProtocol.delay = { _ in 0 }
        StubProtocol.respond = { _ in (204, Data()) }
        radioModel.showRadio()
        try await settle { !radioModel.isRadioLoading }
        expect(!radioModel.isRadioActive && radioModel.radioMessage.contains("上传"), "empty radio explains how to add songs")
        StubProtocol.respond = { _ in throw URLError(.timedOut) }
        radioModel.nextRadioTrack()
        try await settle { !radioModel.isRadioLoading }
        expect(!radioModel.isOnline && radioModel.currentTrack?.id == local.id, "radio timeout falls back to a local song")
        expect(radioModel.isRadioActive && radioModel.radioMessage.contains("离线"), "offline radio remains switchable")
        var localTwo = local
        localTwo.id = UUID()
        radioModel.tracks.append(localTwo)
        radioModel.nextRadioTrack()
        expect(radioModel.currentTrack?.id == localTwo.id && !radioModel.isRadioLoading, "manual offline switch does not wait for a failed server request")
        radioModel.next(automatic: true)
        expect(radioModel.currentTrack?.id == local.id, "offline continuation avoids repeating the previous song")
        radioModel.stop()
        model.persistNow()
        let saved = try String(contentsOf: root.appendingPathComponent("library.json"), encoding: .utf8)
        expect(!saved.contains("test-token"), "credentials never enter library JSON")
        print("Online library checks: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
