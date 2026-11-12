import Foundation
import CryptoKit
import Darwin

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var respond: (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }
    static var delay: (URLRequest) -> TimeInterval = { _ in 0 }
    static var onStart: (URLRequest) -> Void = { _ in }
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.onStart(request)
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

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TrackDownloadProgress] = []
    func append(_ progress: TrackDownloadProgress) {
        lock.lock(); defer { lock.unlock() }
        values.append(progress)
    }
    var snapshot: [TrackDownloadProgress] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

// A loopback HTTP server checks incremental transport progress without
// relying on synthetic byte callbacks or making external requests.
private final class ProgressServer: @unchecked Sendable {
    private let listener: Int32
    private let bytes: Data
    private let catalog: Data
    private let lock = NSLock()
    private var stopped = false
    private var requests: [String] = []
    private var redirectID: UUID?
    let url: URL

    init(bytes: Data, catalog: Data) throws {
        self.bytes = bytes
        self.catalog = catalog
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw POSIXError(.EACCES)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        listener = descriptor
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")!
        DispatchQueue.global().async { [weak self] in
            while true {
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { return }
                guard let self else { close(connection); return }
                DispatchQueue.global().async { self.serve(connection) }
            }
        }
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func redirectAudio(for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        redirectID = id
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        if !alreadyStopped { shutdown(listener, SHUT_RDWR); close(listener) }
    }

    deinit { stop() }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var suppressPipe: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &suppressPipe, socklen_t(MemoryLayout<Int32>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil, request.count < 16_384 {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            request.append(contentsOf: buffer.prefix(count))
        }
        let path = String(decoding: request, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? ""
        lock.lock()
        requests.append(path)
        let redirects = redirectID.map { path == "/api/music/tracks/\($0.uuidString.lowercased())/audio" } ?? false
        lock.unlock()
        if redirects {
            _ = sendAll(Data("HTTP/1.1 302 Found\r\nLocation: /redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection)
            return
        }
        let audio = path.hasSuffix("/audio")
        let body = audio ? bytes : (path == "/api/music/tracks" ? catalog : Data("[]".utf8))
        let header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        guard sendAll(header, to: connection) else { return }
        let chunkSize = audio ? 64 * 1024 : max(1, body.count)
        for offset in stride(from: 0, to: body.count, by: chunkSize) {
            if audio { Thread.sleep(forTimeInterval: 0.08) }
            guard sendAll(body.subdata(in: offset..<min(body.count, offset + chunkSize)), to: connection) else { return }
        }
    }

    private func sendAll(_ data: Data, to connection: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = send(connection, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }
    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.compactMap { $0.url?.path }
    }
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

        // A route/version error is not a disconnected server: keep its catalog online.
        StubProtocol.delay = { _ in 0 }
        StubProtocol.respond = { _ in (200, Data("[]".utf8)) }
        radioModel.reconnect()
        try await settle { !radioModel.isConnecting }
        StubProtocol.respond = { _ in (405, Data()) }
        radioModel.nextRadioTrack()
        try await settle { !radioModel.isRadioLoading }
        expect(radioModel.isOnline, "radio 405 must not disconnect a healthy catalog")
        expect(radioModel.connectionMessage.contains("405"), "radio route error identifies the server response")
        radioModel.stop()
        StubProtocol.respond = { _ in (401, Data()) }
        radioModel.nextRadioTrack()
        try await settle { !radioModel.isRadioLoading }
        expect(!radioModel.isOnline, "radio authentication failure still enters offline mode")
        radioModel.stop()

        // Restore the connection so the late-response cancellation case still
        // exercises a real pending online request after the authentication case.
        StubProtocol.respond = { _ in (200, Data("[]".utf8)) }
        radioModel.reconnect()
        try await settle { !radioModel.isConnecting }
        StubProtocol.respond = { _ in (200, secondPayload) }
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

        // Look-ahead caching uses only stubbed network responses and simulated
        // playback success. No audio player is started by these checks.
        let log = RequestLog()
        StubProtocol.onStart = { log.append($0) }
        let cacheBytes = Data("look-ahead audio fixture".utf8)
        let cacheHash = SHA256.hash(data: cacheBytes).map { String(format: "%02x", $0) }.joined()
        let cacheRecords = (0..<6).map { index in
            ServerTrack(id: UUID(), title: "Upcoming \(index)", artist: "Artist", album: "Album", duration: 12,
                        extension: "mp3", sha256: cacheHash, size: Int64(cacheBytes.count), uploadedAt: "2026-11-12T00:00:00Z")
        }
        func payload(_ records: [ServerTrack]) throws -> Data {
            try JSONSerialization.data(withJSONObject: records.map {
                ["id": $0.id.uuidString, "title": $0.title, "artist": $0.artist, "album": $0.album,
                 "duration": $0.duration, "extension": $0.extension, "sha256": $0.sha256,
                 "size": $0.size, "uploadedAt": $0.uploadedAt] as [String: Any]
            })
        }
        let catalog = try payload(cacheRecords)
        func cacheModel(_ directory: String) throws -> PlayerModel {
            let folder = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(OnlineSettings(server: server.absoluteString)).write(to: folder.appendingPathComponent("online-settings.json"))
            return PlayerModel(storageURL: folder.appendingPathComponent("library.json"), enableSystemControls: false, musicClient: client)
        }
        StubProtocol.delay = { _ in 0 }
        StubProtocol.respond = { request in
            (200, request.url?.path.hasSuffix("/audio") == true ? cacheBytes : catalog)
        }
        let ahead = try cacheModel("ahead")
        ahead.reconnect()
        try await settle { !ahead.isConnecting }
        let cacheSongs = try cacheRecords.map { try $0.track(server: server, cacheRoot: ahead.musicCacheURL) }
        let localCurrent = Track(url: local.url, title: "Current", artist: "Artist", album: "Album", duration: 12)
        ahead.tracks.append(localCurrent)
        ahead.queue = PlaybackQueue(ids: [localCurrent.id] + cacheSongs.map(\.id))
        ahead.mode = .sequential
        let beforeCache = log.paths.count
        ahead.playbackDidStart(successfully: true)
        try await settle { cacheSongs.prefix(3).allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) } }
        expect(cacheSongs.dropFirst(3).allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) }, "cache exactly the next three queue positions")
        expect(ahead.currentTrack?.id == localCurrent.id && ahead.isPlaying && ahead.loadingTrackID == nil, "prefetch preserves current playback and foreground loading state")
        expect(cacheSongs.allSatisfy { ahead.track(for: $0.id)?.playCount == 0 }, "prefetch does not count future songs as played")
        expect(log.paths.count - beforeCache == 3, "three future songs require three audio downloads")
        let beforeSkip = log.paths.count
        ahead.next()
        expect(ahead.currentTrack?.id == cacheSongs[0].id, "skip uses the first prepared song")
        ahead.playbackDidStart(successfully: true)
        try await settle { FileManager.default.fileExists(atPath: cacheSongs[3].url.path) }
        expect(log.paths.count - beforeSkip == 1, "advancing replenishes one song and reuses the previous two cached songs")
        ahead.pause()

        ahead.tracks.append(local)
        ahead.queue = PlaybackQueue(ids: [localCurrent.id, cacheSongs[0].id, local.id, cacheSongs[4].id, cacheSongs[5].id])
        let beforeMixed = log.paths.count
        ahead.playbackDidStart(successfully: true)
        try await settle { FileManager.default.fileExists(atPath: cacheSongs[4].url.path) }
        expect(log.paths.count - beforeMixed == 1 && !FileManager.default.fileExists(atPath: cacheSongs[5].url.path), "local and cached songs occupy upcoming slots without downloading farther ahead")
        ahead.pause()

        let queueIDs = cacheSongs.map(\.id)
        let tail = PlaybackQueue(ids: queueIDs, startingAt: queueIDs[4])
        expect(tail.upcomingIDs(mode: .sequential) == [queueIDs[5]], "sequential look-ahead stops at the queue end")
        expect(tail.upcomingIDs(mode: .loopAll) == [queueIDs[5], queueIDs[0], queueIDs[1]], "loop look-ahead wraps in playback order")
        expect(tail.upcomingIDs(mode: .shuffle) == [queueIDs[5], queueIDs[0], queueIDs[1]], "shuffle uses the queue's already shuffled order")
        expect(PlaybackQueue(ids: [queueIDs[0]]).upcomingIDs(mode: .loopAll).isEmpty, "one-song queues do not redownload the current song")

        // A failed speculative request is silent and does not mark the catalog offline.
        let failuresModel = try cacheModel("cache-failure")
        failuresModel.reconnect()
        try await settle { !failuresModel.isConnecting }
        let failureSongs = try cacheRecords.map { try $0.track(server: server, cacheRoot: failuresModel.musicCacheURL) }
        failuresModel.tracks.append(localCurrent)
        failuresModel.queue = PlaybackQueue(ids: [localCurrent.id] + failureSongs.map(\.id))
        let failedPath = "/api/music/tracks/\(cacheRecords[0].id.uuidString.lowercased())/audio"
        StubProtocol.respond = { request in
            (request.url?.path == failedPath ? 500 : 200, cacheBytes)
        }
        failuresModel.playbackDidStart(successfully: true)
        try await settle { FileManager.default.fileExists(atPath: failureSongs[2].url.path) }
        expect(failuresModel.isOnline && failuresModel.isPlaying && failuresModel.notice == nil, "background failure does not interrupt playback or show a foreground error")
        expect(!FileManager.default.fileExists(atPath: failureSongs[0].url.path), "failed prefetch never creates an offline cache")
        failuresModel.stop()

        // Stopping cancels in-flight look-ahead instead of downloading the whole queue.
        StubProtocol.delay = { $0.url?.path.hasSuffix("/audio") == true ? 0.2 : 0 }
        StubProtocol.respond = { request in
            (200, request.url?.path.hasSuffix("/audio") == true ? cacheBytes : catalog)
        }
        let beforeCancel = log.paths.count
        ahead.queue = PlaybackQueue(ids: [localCurrent.id, cacheSongs[5].id])
        ahead.playbackDidStart(successfully: true)
        try await settle { log.paths.count > beforeCancel }
        ahead.reconnect()
        try await settle { !ahead.isConnecting }
        try await Task.sleep(for: .milliseconds(20))
        expect(log.paths.dropFirst(beforeCancel).filter { $0.hasSuffix("/audio") }.count == 1, "periodic catalog refresh keeps the in-flight prefetch instead of restarting it")
        ahead.stop()
        try await Task.sleep(for: .milliseconds(250))
        expect(!FileManager.default.fileExists(atPath: cacheSongs[5].url.path), "stop cancels the active prefetch and prevents later downloads")

        let beforeClear = log.paths.count
        ahead.playbackDidStart(successfully: true)
        try await settle { log.paths.count > beforeClear }
        ahead.clearUpcoming()
        try await Task.sleep(for: .milliseconds(250))
        expect(ahead.isPlaying && !FileManager.default.fileExists(atPath: cacheSongs[5].url.path), "editing the upcoming queue cancels stale prefetch without pausing the current song")
        ahead.pause()

        // Two consumers share one authenticated download; cancelling one keeps
        // the other consumer's transfer alive.
        let shared = try cacheRecords[5].track(server: server, cacheRoot: root.appendingPathComponent("shared"))
        StubProtocol.respond = { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer shared-token" ? (200, cacheBytes) : (401, Data())
        }
        let beforeShared = log.paths.count
        let speculative = Task { try await client.download(shared, token: "shared-token") }
        let foreground = Task { try await client.download(shared, token: "shared-token") }
        try await settle { log.paths.count > beforeShared }
        speculative.cancel()
        try await foreground.value
        do { try await speculative.value; expect(false, "cancelled consumer must throw") } catch { }
        expect(log.paths.count - beforeShared == 1 && (try? Data(contentsOf: shared.url)) == cacheBytes, "foreground playback shares the pending cache download without being cancelled")

        // Deliver bytes over time so progress must come from real download
        // task byte counts, including a foreground consumer joining a prefetch.
        let progressBytes = Data(repeating: 7, count: 512 * 1024)
        let progressHash = SHA256.hash(data: progressBytes).map { String(format: "%02x", $0) }.joined()
        let progressRecords = (0..<2).map { index in
            ServerTrack(id: UUID(), title: "Progress \(index)", artist: "Artist", album: "Album", duration: 12,
                        extension: "mp3", sha256: progressHash, size: Int64(progressBytes.count), uploadedAt: "2026-11-12T00:00:00Z")
        }
        let progressCatalog = try payload(progressRecords)
        let progressServer = try ProgressServer(bytes: progressBytes, catalog: progressCatalog)
        defer { progressServer.stop() }
        let streamClient = OnlineMusicClient()
        let progressSong = try progressRecords[0].track(server: progressServer.url, cacheRoot: root.appendingPathComponent("progress-shared"))
        let firstProgress = ProgressLog()
        let joinedProgress = ProgressLog()
        StubProtocol.delay = { _ in 0 }
        let beforeProgress = progressServer.paths.count
        let prefetchProgress = Task { try await streamClient.download(progressSong, token: "", onProgress: { firstProgress.append($0) }) }
        try await settle { firstProgress.snapshot.contains { $0.fraction > 0 && $0.fraction < 1 } }
        let foregroundProgress = Task { try await streamClient.download(progressSong, token: "", onProgress: { joinedProgress.append($0) }) }
        try await settle { !joinedProgress.snapshot.isEmpty }
        expect(joinedProgress.snapshot.first?.fraction ?? 0 > 0, "joining a prefetch immediately receives its current downloaded bytes")
        prefetchProgress.cancel()
        try await foregroundProgress.value
        do { try await prefetchProgress.value; expect(false, "cancelled progress consumer must throw") } catch { }
        let deliveredProgress = joinedProgress.snapshot
        expect(deliveredProgress.last?.phase == .complete && deliveredProgress.last?.receivedBytes == Int64(progressBytes.count), "progress reaches completion only after the verified file is saved")
        expect(zip(deliveredProgress, deliveredProgress.dropFirst()).allSatisfy { $0.receivedBytes <= $1.receivedBytes && $0.phase.rawValue <= $1.phase.rawValue }, "shared download progress never moves backwards")
        expect(progressServer.paths.count - beforeProgress == 1, "progress subscribers still share a single transfer")

        let progressRoot = root.appendingPathComponent("current-progress")
        try FileManager.default.createDirectory(at: progressRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(OnlineSettings(server: progressServer.url.absoluteString)).write(to: progressRoot.appendingPathComponent("online-settings.json"))
        let progressModel = PlayerModel(storageURL: progressRoot.appendingPathComponent("library.json"), enableSystemControls: false, musicClient: streamClient)
        progressModel.reconnect()
        try await settle { !progressModel.isConnecting }
        let progressSongs = try progressRecords.map { try $0.track(server: progressServer.url, cacheRoot: progressModel.musicCacheURL) }
        progressModel.playTrack(progressSongs[0].id, in: progressSongs.map(\.id))
        try await settle { progressModel.downloadProgress.active?.progress.fraction ?? 0 > 0 }
        expect(progressModel.downloadProgress.active?.trackID == progressSongs[0].id, "current song exposes live downloaded bytes")
        progressModel.playTrack(progressSongs[1].id, in: progressSongs.map(\.id))
        expect(progressModel.downloadProgress.active?.trackID == progressSongs[1].id && progressModel.downloadProgress.active?.progress.percentage == 0, "switching songs resets the progress to the new download")
        try await settle { progressModel.downloadProgress.active?.progress.fraction ?? 0 > 0 }
        expect(progressModel.downloadProgress.active?.trackID == progressSongs[1].id, "late progress from the previous song cannot replace the current download")
        progressModel.pause()
        try await Task.sleep(for: .milliseconds(100))
        expect(progressModel.downloadProgress.active == nil && progressModel.loadingTrackID == nil, "cancelling the current download clears the progress and ignores late callbacks")
        progressServer.redirectAudio(for: progressRecords[1].id)
        let redirectedSong = try progressRecords[1].track(server: progressServer.url, cacheRoot: root.appendingPathComponent("redirect-check"))
        do {
            try await streamClient.download(redirectedSong, token: "local-redirect-test")
            expect(false, "audio redirects must fail")
        } catch {
            if case .http(302) = error as? OnlineLibraryError { }
            else { expect(false, "redirect must be rejected before a follow-up request") }
        }
        expect(!progressServer.paths.contains("/redirected"), "the progress download task preserves the no-redirect credential policy")
        print("PASS: real byte progress, shared transfer replay, phase order, track switching and cancellation")

        // Radio prepares three real future selections, then consumes them in
        // that order and replenishes the buffer after each successful start.
        StubProtocol.delay = { _ in 0 }
        let firstCachePayload = try JSONSerialization.data(withJSONObject: (try JSONSerialization.jsonObject(with: catalog) as! [[String: Any]])[0])
        StubProtocol.respond = { request in
            if request.url?.path.hasSuffix("/radio") == true { return (200, firstCachePayload) }
            return (200, request.url?.path.hasSuffix("/audio") == true ? cacheBytes : catalog)
        }
        let bufferedRadio = try cacheModel("radio-ahead")
        let radioSongs = try cacheRecords.map { try $0.track(server: server, cacheRoot: bufferedRadio.musicCacheURL) }
        try FileManager.default.createDirectory(at: bufferedRadio.musicCacheURL, withIntermediateDirectories: true)
        try cacheBytes.write(to: radioSongs[0].url)
        bufferedRadio.showRadio()
        try await settle { !bufferedRadio.isRadioLoading }
        let catalogsBeforeRadioCache = log.paths.filter { $0 == "/api/music/tracks" }.count
        bufferedRadio.playbackDidStart(successfully: true)
        try await settle {
            bufferedRadio.radioUpcomingIDs.count == 3 && bufferedRadio.radioUpcomingIDs.allSatisfy {
                bufferedRadio.track(for: $0).map { FileManager.default.fileExists(atPath: $0.url.path) } == true
            }
        }
        let prepared = bufferedRadio.radioUpcomingIDs
        expect(log.paths.filter { $0 == "/api/music/tracks" }.count == catalogsBeforeRadioCache + 1, "radio loads its catalog once when entered before library sync")
        expect(Set(prepared).count == 3 && !prepared.contains(radioSongs[0].id), "radio chooses three distinct future songs when the catalog has enough songs")
        let beforeRadioSkip = log.paths.count
        bufferedRadio.nextRadioTrack()
        expect(bufferedRadio.radioTrackID == prepared[0] && bufferedRadio.queue.ids == [prepared[0]], "radio skip consumes the prepared selection and keeps the single-song queue")
        expect(log.paths.count == beforeRadioSkip, "cached radio skip needs no selection or audio request")
        bufferedRadio.playbackDidStart(successfully: true)
        try await settle {
            bufferedRadio.radioUpcomingIDs.count == 3 && bufferedRadio.radioUpcomingIDs.allSatisfy {
                bufferedRadio.track(for: $0).map { FileManager.default.fileExists(atPath: $0.url.path) } == true
            }
        }
        expect(Array(bufferedRadio.radioUpcomingIDs.prefix(2)) == Array(prepared.suffix(2)), "radio refill preserves the next two prepared selections")
        bufferedRadio.useOfflineMode(message: "test offline")
        let offlineNext = bufferedRadio.radioUpcomingIDs.first
        bufferedRadio.nextRadioTrack()
        expect(bufferedRadio.radioTrackID == offlineNext && !bufferedRadio.isRadioLoading, "radio can consume its prepared cache after disconnecting")
        bufferedRadio.stop()
        bufferedRadio.playTrack(localCurrent.id, in: [localCurrent.id])
        expect(bufferedRadio.radioUpcomingIDs.isEmpty, "leaving radio discards its speculative selections")
        StubProtocol.onStart = { _ in }
        StubProtocol.delay = { _ in 0 }
        print("PASS: next-three cache, queue order/refill, failure isolation, cancellation, shared downloads and radio buffer")

        let playlistID = UUID(), secondPlaylistID = UUID()
        let onlineLists = [ServerPlaylist(id: playlistID, name: "夜间电台精选", trackIds: [secondID, record.id]),
                           ServerPlaylist(id: secondPlaylistID, name: "共享曲目", trackIds: [record.id])]
        let playlistPayload = try JSONEncoder().encode(onlineLists)
        StubProtocol.respond = { request in
            guard request.url?.path == "/api/music/playlists", request.value(forHTTPHeaderField: "Authorization") == "Bearer playlist-token" else { throw URLError(.badURL) }
            return (200, playlistPayload)
        }
        let fetchedLists = try await client.playlists(server: server, token: "playlist-token")
        expect(fetchedLists == onlineLists, "playlist endpoint authenticates and preserves membership order")
        let playlistModel = PlayerModel(storageURL: root.appendingPathComponent("playlists/library.json"), enableSystemControls: false, musicClient: client)
        let songsPayload = Data("[".utf8) + firstPayload + Data(",".utf8) + secondPayload + Data("]".utf8)
        StubProtocol.respond = { request in (200, request.url?.path == "/api/music/playlists" ? playlistPayload : songsPayload) }
        playlistModel.reconnect()
        try await settle { !playlistModel.isConnecting }
        expect(playlistModel.isOnline && playlistModel.onlinePlaylists == onlineLists, "refresh loads shared server playlists")
        let browsingQueue = playlistModel.queue
        playlistModel.search = "stale track query"
        playlistModel.showPlaylists(online: true)
        expect(playlistModel.section == .onlinePlaylists && playlistModel.search.isEmpty && playlistModel.sectionTracks.isEmpty, "online sidebar opens the playlist collection without flattening songs")
        expect(playlistModel.playlistSummaries(online: true).map(\.id) == [playlistID, secondPlaylistID], "collection contains all server playlists")
        expect(playlistModel.playlistSummaries(online: true).map(\.trackCount) == [2, 1], "collection shows each playlist's full song count")
        playlistModel.search = "共享"
        expect(playlistModel.playlistSummaries(online: true).map(\.id) == [secondPlaylistID], "collection search matches playlist names")
        playlistModel.showPlaylist(playlistID, online: true)
        expect(playlistModel.section == .onlinePlaylist(playlistID) && playlistModel.search.isEmpty && playlistModel.queue == browsingQueue, "opening playlist details leaves playback intact")
        expect(playlistModel.section.isOnlinePlaylistNavigation && !playlistModel.section.isLocalPlaylistNavigation, "sidebar keeps the correct parent selected")
        playlistModel.section = .onlinePlaylist(playlistID)
        expect(playlistModel.visibleTracks.compactMap { $0.remoteSource?.id } == [secondID, record.id], "selecting an online playlist shows its songs in server order")
        StubProtocol.delay = { _ in 0.5 }
        playlistModel.playAll()
        expect(playlistModel.queue.ids == playlistModel.visibleTracks.map(\.id), "play-all queues only the selected online playlist")
        playlistModel.pause()
        // A global library sort cannot override the order saved by the server.
        for sort in TrackSort.allCases {
            playlistModel.sort = sort
            expect(playlistModel.visibleTracks.compactMap { $0.remoteSource?.id } == [secondID, record.id], "online playlist order ignores library sort \(sort.rawValue)")
        }
        let orderedLists = [ServerPlaylist(id: playlistID, name: "夜间电台精选", trackIds: [record.id, secondID]), onlineLists[1]]
        playlistModel.mergeOnlinePlaylists(orderedLists, server: try OnlineSettings.serverURL(playlistModel.onlineSettings.server))
        expect(playlistModel.visibleTracks.compactMap { $0.remoteSource?.id } == [record.id, secondID], "server reorder updates the visible playlist without losing membership")
        playlistModel.playAll()
        expect(playlistModel.queue.ids == playlistModel.visibleTracks.map(\.id), "play-all follows the reordered server list")
        playlistModel.pause()
        playlistModel.next()
        expect(playlistModel.currentTrack?.remoteSource?.id == secondID, "next song follows the reordered queue")
        playlistModel.pause()
        // Restore the original order for the existing offline persistence scenarios.
        playlistModel.mergeOnlinePlaylists(onlineLists, server: try OnlineSettings.serverURL(playlistModel.onlineSettings.server))
        StubProtocol.delay = { _ in 0 }
        let cachedPlaylistSong = playlistModel.sectionTracks[0]
        try FileManager.default.createDirectory(at: cachedPlaylistSong.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("offline fixture".utf8).write(to: cachedPlaylistSong.url)
        playlistModel.useOfflineMode(message: "offline")
        expect(playlistModel.onlinePlaylists.count == 2 && playlistModel.visibleTracks.map(\.id) == [cachedPlaylistSong.id], "offline playlist keeps metadata and exposes only cached audio")
        playlistModel.playlists = [Playlist(id: playlistID, name: "Local list", trackIDs: [cachedPlaylistSong.id])]
        playlistModel.persistNow()
        let restoredPlaylists = PlayerModel(storageURL: root.appendingPathComponent("playlists/library.json"), enableSystemControls: false, musicClient: client)
        restoredPlaylists.section = .onlinePlaylist(playlistID)
        expect(restoredPlaylists.onlinePlaylists == onlineLists && restoredPlaylists.visibleTracks.map(\.id) == [cachedPlaylistSong.id], "server playlists and cached playback survive relaunch offline")
        restoredPlaylists.section = .playlist(playlistID)
        expect(restoredPlaylists.sectionTitle == "Local list", "online and local playlists have separate identities")
        StubProtocol.respond = { request in request.url?.path == "/api/music/playlists" ? (405, Data()) : (200, songsPayload) }
        playlistModel.reconnect()
        try await settle { !playlistModel.isConnecting }
        expect(playlistModel.isOnline && playlistModel.onlinePlaylists == onlineLists && playlistModel.onlinePlaylistMessage.contains("405"), "playlist endpoint failure preserves a healthy catalog and cached lists")
        let alternateServer = URL(string: "https://other.test")!
        playlistModel.mergeOnlinePlaylists([], server: alternateServer)
        expect(playlistModel.onlinePlaylists == onlineLists, "playlist cache is scoped to each server")
        playlistModel.section = .onlinePlaylist(playlistID)
        playlistModel.mergeOnlinePlaylists([], server: try OnlineSettings.serverURL(playlistModel.onlineSettings.server))
        expect(playlistModel.section == .onlinePlaylists && playlistModel.onlinePlaylists.isEmpty, "deleted online playlist returns to its collection")
        playlistModel.stop()
        restoredPlaylists.stop()
        print("PASS: authenticated online playlists, ordered playback, offline cache, relaunch, server scope and failure isolation")
        let maintenanceRoot = root.appendingPathComponent("maintenance")
        let maintenance = PlayerModel(storageURL: maintenanceRoot.appendingPathComponent("library.json"), enableSystemControls: false, musicClient: client)
        let targetServer = try OnlineSettings.serverURL(maintenance.onlineSettings.server)
        let remoteRecord = ServerTrack(id: UUID(), title: "Delete me", artist: "Test", album: "Test", duration: 0, extension: "mp3", sha256: String(repeating: "b", count: 64), size: 7, uploadedAt: "2026-11-13T00:00:00Z")
        var remoteSong = try remoteRecord.track(server: targetServer, cacheRoot: maintenance.musicCacheURL)
        remoteSong.isFavorite = true
        let originalURL = maintenanceRoot.appendingPathComponent("original.mp3")
        try FileManager.default.createDirectory(at: maintenance.musicCacheURL, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: originalURL)
        let original = Track(url: originalURL, title: "Original", artist: "Artist", album: "Album", duration: 0)
        maintenance.tracks = [original, remoteSong]
        maintenance.playlists = [Playlist(name: "Keep", trackIDs: [original.id, remoteSong.id])]
        try Data("fixture".utf8).write(to: remoteSong.url)
        try Data("orphan".utf8).write(to: maintenance.musicCacheURL.appendingPathComponent("orphan.tmp"))
        await maintenance.clearOnlineCache()
        expect(!remoteSong.hasLocalCopy && original.hasLocalCopy && maintenance.track(for: remoteSong.id)?.isFavorite == true, "clear cache removes audio but preserves local originals and favorites")
        expect(maintenance.playlists[0].trackIDs == [original.id, remoteSong.id] && maintenance.onlineCacheBytes == 0, "clear cache preserves playlist refs and removes orphan files")
        try Data("fixture".utf8).write(to: remoteSong.url)
        StubProtocol.respond = { _ in (503, Data()) }
        await maintenance.deleteTrack(remoteSong.id, fromCloud: true, localFile: false)
        expect(maintenance.track(for: remoteSong.id) != nil && remoteSong.hasLocalCopy, "failed server deletion preserves local metadata and cache")
        var deleteRequestValid = false
        StubProtocol.respond = { request in
            deleteRequestValid = request.httpMethod == "DELETE" && request.url?.lastPathComponent == remoteRecord.id.uuidString.lowercased()
            return (204, Data())
        }
        await maintenance.deleteTrack(remoteSong.id, fromCloud: true, localFile: false)
        expect(deleteRequestValid && maintenance.track(for: remoteSong.id) == nil && !remoteSong.hasLocalCopy, "successful deletion removes cloud metadata and file")
        expect(maintenance.playlists[0].trackIDs == [original.id], "deleted songs leave no local playlist refs")

        let uploadJSON = try JSONSerialization.data(withJSONObject: ["id": remoteRecord.id.uuidString, "title": "Original", "artist": "Artist", "album": "Album", "duration": 0, "extension": "mp3", "sha256": remoteRecord.sha256, "size": 7, "uploadedAt": "2026-11-13T00:00:00Z"])
        var uploads = 0
        StubProtocol.respond = { request in
            expect(request.httpMethod == "POST" && request.url?.query == "reuseExisting=true", "upload uses authenticated reuse endpoint")
            uploads += 1; return (201, uploadJSON)
        }
        remoteSong.playCount = 8
        maintenance.tracks.append(remoteSong)
        maintenance.playlists[0].trackIDs = [remoteSong.id, original.id]
        await maintenance.uploadToCloud(trackID: original.id)
        expect(maintenance.playlists[0].trackIDs == [original.id] && maintenance.tracks.first?.isFavorite == true && maintenance.tracks.first?.playCount == 8, "upload coalesces existing cloud row without losing favorites, counts or playlist references")
        await maintenance.uploadToCloud(trackID: original.id)
        expect(uploads == 1 && maintenance.tracks.count == 1, "repeated song upload reuses associated cloud copy without duplicate rows")
        expect(maintenance.track(for: original.id)?.hasCloudCopy == true && original.hasLocalCopy, "uploaded original displays local and cloud sources")
        maintenance.mergeOnlineTracks([try remoteRecord.track(server: targetServer, cacheRoot: maintenance.musicCacheURL)])
        expect(maintenance.tracks.count == 1 && maintenance.tracks[0].id == original.id, "catalog refresh retains linked original identity")
        StubProtocol.respond = { _ in (200, uploadJSON) }
        maintenance.nextRadioTrack()
        try await settle { !maintenance.isRadioLoading }
        expect(maintenance.queue.currentID == original.id && maintenance.currentTrack?.id == original.id && maintenance.isOnline, "radio resolves uploaded cloud identity to original local song")
        maintenance.pause()
        maintenance.persistNow()
        let reloaded = PlayerModel(storageURL: maintenanceRoot.appendingPathComponent("library.json"), enableSystemControls: false, musicClient: client)
        expect(reloaded.tracks[0].hasCloudCopy && reloaded.tracks[0].url == originalURL, "uploaded sources survive relaunch")
        try await maintenance.synchronizeCatalog([], server: targetServer)
        expect(maintenance.tracks[0].cloudSources.isEmpty && original.hasLocalCopy, "server deletion unlinks original without deleting the original file")
        var deletedRemote = remoteSong
        deletedRemote.artworkData = Data([1])
        maintenance.tracks.append(deletedRemote)
        try Data("fixture".utf8).write(to: remoteSong.url)
        try await maintenance.synchronizeCatalog([], server: targetServer)
        expect(maintenance.track(for: remoteSong.id) == nil && !remoteSong.hasLocalCopy, "authoritative catalog prunes deleted server song and cache")
        let listToUpload = Playlist(name: "Ordered upload", trackIDs: [])
        let firstCloudID = UUID(), secondCloudID = UUID()
        var finalOrder: [String] = []
        StubProtocol.respond = { request in
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
            }
            let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
            let ids = body["trackIds"] as? [String] ?? []
            let path = request.url!.path
            if path.hasSuffix("/order") { finalOrder = ids }
            let reply: [String: Any] = ["id": listToUpload.id.uuidString, "name": listToUpload.name, "trackIds": path.hasSuffix("/order") ? ids : (path.hasSuffix("/tracks") ? [secondCloudID.uuidString.lowercased(), firstCloudID.uuidString.lowercased()] : [])]
            return (path == "/api/music/playlists" ? 201 : 200, try JSONSerialization.data(withJSONObject: reply))
        }
        let uploadedOrder = try await client.uploadPlaylist(listToUpload, trackIDs: [firstCloudID, secondCloudID], server: targetServer, token: "test-token")
        expect(uploadedOrder.trackIds == [firstCloudID, secondCloudID] && finalOrder == [firstCloudID.uuidString.lowercased(), secondCloudID.uuidString.lowercased()], "playlist upload preserves local order using compare-and-set reorder")
        let drainingModel = PlayerModel(storageURL: root.appendingPathComponent("draining/library.json"), enableSystemControls: false, musicClient: streamClient)
        let drainingSong = try progressRecords[0].track(server: progressServer.url, cacheRoot: drainingModel.musicCacheURL)
        drainingModel.tracks = [drainingSong]
        let drainingTask = Task { try await streamClient.download(drainingSong, token: "test-token") }
        try await Task.sleep(for: .milliseconds(150))
        await drainingModel.clearOnlineCache()
        _ = await drainingTask.result
        try await Task.sleep(for: .milliseconds(100))
        expect(!drainingSong.hasLocalCopy && drainingModel.onlineCacheBytes == 0, "clear cache drains in-flight writer so cancelled download cannot recreate file")
        print("PASS: deletion failure/success, cache eviction, linked uploads, repeat upload and authoritative reconciliation")
        model.persistNow()
        let saved = try String(contentsOf: root.appendingPathComponent("library.json"), encoding: .utf8)
        expect(!saved.contains("test-token"), "credentials never enter library JSON")
        print("Online library checks: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
