import Foundation
import CryptoKit
import Security

struct RemoteTrackSource: Codable, Equatable, Sendable {
    let server: URL
    let id: UUID
    let sha256: String
    let size: Int64
    var cacheID: UUID {
        let bytes = Array(SHA256.hash(data: Data("\(server.absoluteString)/\(id.uuidString)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct OnlineSettings: Codable, Equatable, Sendable {
    var enabled = true
    var server = "https://121.40.254.112"

    static func serverURL(_ text: String) throws -> URL {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw OnlineLibraryError.message("请输入 HTTPS 服务器地址；本机开发可使用 http://127.0.0.1:8080。")
        }
        parts.path = ""
        return parts.url!
    }
}

enum OnlineLibraryError: LocalizedError {
    case message(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(401), .http(403): return "服务器认证失败，请在连接设置中检查访问令牌。"
        case .http(let code): return "服务器请求失败（HTTP \(code)），请稍后重试。"
        }
    }

    // An unavailable feature or invalid song does not mean the server disconnected.
    static func requiresOfflineMode(_ error: Error) -> Bool {
        if case .http(let code) = error as? OnlineLibraryError { return code == 401 || code == 403 }
        return error is URLError
    }
}

struct ServerPlaylist: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let trackIds: [UUID]
}

struct ServerTrack: Decodable, Sendable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let `extension`: String
    let sha256: String
    let size: Int64
    let uploadedAt: String

    func track(server: URL, cacheRoot: URL) throws -> Track {
        guard TrackImporter.extensions.contains(`extension`),
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              size > 0, size <= 128 * 1024 * 1024, duration.isFinite, duration >= 0 else {
            throw OnlineLibraryError.message("服务器歌曲信息无效，请更新服务端后重试。")
        }
        let identity = Array(SHA256.hash(data: Data("\(server.absoluteString)/\(id.uuidString)".utf8)).prefix(16))
        let uuid = UUID(uuid: (identity[0], identity[1], identity[2], identity[3], identity[4], identity[5], identity[6], identity[7],
                               identity[8], identity[9], identity[10], identity[11], identity[12], identity[13], identity[14], identity[15]))
        let date = ISO8601DateFormatter().date(from: uploadedAt) ?? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: uploadedAt) ?? Date(timeIntervalSince1970: 0)
        }()
        return Track(id: uuid, url: cacheRoot.appendingPathComponent("\(uuid.uuidString)-\(sha256).\(`extension`)"),
                     title: title, artist: artist, album: album, duration: duration, importedAt: date,
                     remoteSource: RemoteTrackSource(server: server, id: id, sha256: sha256, size: size))
    }
}

// Ephemeral requests never write the access token or authenticated responses to disk.
// Redirects are rejected so credentials cannot leave the configured server.
struct TrackDownloadProgress: Equatable, Sendable {
    enum Phase: Int, Sendable { case downloading, verifying, complete, preparing }
    let receivedBytes: Int64
    let totalBytes: Int64
    var phase: Phase = .downloading

    var fraction: Double { min(1, max(0, Double(receivedBytes) / Double(max(1, totalBytes)))) }
    var percentage: Int { Int(fraction * 100) }
    var byteDescription: String {
        "\(ByteCountFormatter.string(fromByteCount: min(max(0, receivedBytes), totalBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
    }
    var status: String {
        switch phase {
        case .downloading: return "正在下载"
        case .verifying: return "下载完成，正在校验"
        case .complete, .preparing: return "正在准备播放"
        }
    }
}

typealias DownloadProgressHandler = @Sendable (TrackDownloadProgress) -> Void

final class MusicRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Observe the actual task's received bytes: async download(for:) does not
// forward download-delegate callbacks on every supported Foundation version.
private final class MusicFileDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func run(session: URLSession, request: URLRequest,
             onBytes: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { temporary, response, error in
                    self.finish()
                    if let error { continuation.resume(throwing: error); return }
                    guard let temporary, let response else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    do {
                        // URLSession removes its file after this callback returns.
                        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("sonora-download-\(UUID())")
                        try FileManager.default.moveItem(at: temporary, to: owned)
                        continuation.resume(returning: (owned, response))
                    } catch { continuation.resume(throwing: error) }
                }
                task.delegate = MusicRequestDelegate()
                let observation = task.observe(\.countOfBytesReceived, options: [.initial, .new]) { task, _ in
                    onBytes(task.countOfBytesReceived)
                }
                lock.lock()
                self.task = task
                self.observation = observation
                let shouldCancel = cancelled
                lock.unlock()
                if shouldCancel { task.cancel() } else { task.resume() }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let active = task
        lock.unlock()
        active?.cancel()
    }

    private func finish() {
        lock.lock()
        let observation = self.observation
        self.observation = nil
        task = nil
        lock.unlock()
        observation?.invalidate()
    }
}

// Playback and look-ahead caching share a transfer. Cancelling one consumer
// only cancels the network request when nobody else still needs the file.
private actor MusicDownloadCache {
    private struct Transfer {
        let id: UUID
        let task: Task<Void, Error>
        var consumers: [UUID: DownloadProgressHandler]
        var progress: TrackDownloadProgress
        var lastBroadcast: TimeInterval = 0
    }
    private var transfers: [URL: Transfer] = [:]
    private var retiring: [UUID: Task<Void, Error>] = [:]

    func cancelAndDrain() async {
        let pending = Array(transfers.values.map(\.task)) + Array(retiring.values)
        transfers.removeAll()
        retiring.removeAll()
        pending.forEach { $0.cancel() }
        for task in pending { _ = await task.result }
    }

    func download(to url: URL, totalBytes: Int64, onProgress: DownloadProgressHandler?,
                  operation: @escaping @Sendable (@escaping DownloadProgressHandler) async throws -> Void) async throws {
        try Task.checkCancellation()
        let consumer = UUID()
        let task: Task<Void, Error>
        let transferID: UUID
        let callback: DownloadProgressHandler = onProgress ?? { _ in }
        if var transfer = transfers[url] {
            transfer.consumers[consumer] = callback
            transfers[url] = transfer
            task = transfer.task
            transferID = transfer.id
            callback(transfer.progress)
        } else {
            if FileManager.default.fileExists(atPath: url.path) {
                callback(TrackDownloadProgress(receivedBytes: totalBytes, totalBytes: totalBytes, phase: .complete))
                return
            }
            transferID = UUID()
            let report: DownloadProgressHandler = { [weak self] progress in
                Task { await self?.report(progress, for: url, transferID: transferID) }
            }
            task = Task { try await operation(report) }
            let initial = TrackDownloadProgress(receivedBytes: 0, totalBytes: totalBytes)
            transfers[url] = Transfer(id: transferID, task: task, consumers: [consumer: callback], progress: initial)
            callback(initial)
        }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            Task { await self.release(consumer, for: url) }
        }
        if case .success = result {
            report(TrackDownloadProgress(receivedBytes: totalBytes, totalBytes: totalBytes, phase: .complete),
                   for: url, transferID: transferID)
        }
        release(consumer, for: url)
        try Task.checkCancellation()
        try result.get()
    }

    private func report(_ progress: TrackDownloadProgress, for url: URL, transferID: UUID) {
        guard var transfer = transfers[url], transfer.id == transferID,
              progress.phase.rawValue >= transfer.progress.phase.rawValue,
              progress.receivedBytes >= transfer.progress.receivedBytes else { return }
        let phaseChanged = progress.phase != transfer.progress.phase
        let now = ProcessInfo.processInfo.systemUptime
        transfer.progress = progress
        // Keep the latest value for consumers joining a prefetch, while limiting
        // UI callbacks to ten per second plus phase changes and the final bytes.
        let broadcast = phaseChanged || progress.fraction >= 1 || now - transfer.lastBroadcast >= 0.1
        if broadcast { transfer.lastBroadcast = now }
        transfers[url] = transfer
        if broadcast { transfer.consumers.values.forEach { $0(progress) } }
    }

    private func release(_ consumer: UUID, for url: URL) {
        guard var transfer = transfers[url], transfer.consumers.removeValue(forKey: consumer) != nil else { return }
        if transfer.consumers.isEmpty {
            transfer.task.cancel()
            transfers[url] = nil
            let id = transfer.id
            retiring[id] = transfer.task
            Task { _ = await transfer.task.result; self.finishedRetiring(id) }
        } else { transfers[url] = transfer }
    }

    private func finishedRetiring(_ id: UUID) { retiring[id] = nil }
}

struct OnlineMusicClient: Sendable {
    let session: URLSession
    private let downloads = MusicDownloadCache()
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: MusicRequestDelegate(), delegateQueue: nil)
    }

    private func request(_ url: URL, token: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw OnlineLibraryError.message("服务器响应格式无效。")
        }
        guard response.statusCode == 200 else { throw OnlineLibraryError.http(response.statusCode) }
    }

    func list(server: URL, token: String) async throws -> [ServerTrack] {
        let (data, response) = try await session.data(for: request(server.appendingPathComponent("api/music/tracks"), token: token, timeout: 6))
        try check(response)
        return try JSONDecoder().decode([ServerTrack].self, from: data)
    }

    func playlists(server: URL, token: String) async throws -> [ServerPlaylist] {
        let (data, response) = try await session.data(for: request(server.appendingPathComponent("api/music/playlists"), token: token, timeout: 6))
        try check(response)
        let lists = try JSONDecoder().decode([ServerPlaylist].self, from: data)
        guard Set(lists.map(\.id)).count == lists.count,
              lists.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 80 && $0.trackIds.count <= 10000 && Set($0.trackIds).count == $0.trackIds.count }) else {
            throw OnlineLibraryError.message("在线歌单信息无效，请刷新或更新服务端。")
        }
        return lists
    }

    func radio(server: URL, token: String, excluding id: UUID?) async throws -> ServerTrack? {
        var parts = URLComponents(url: server.appendingPathComponent("api/music/tracks/radio"), resolvingAgainstBaseURL: false)!
        if let id { parts.queryItems = [URLQueryItem(name: "exclude", value: id.uuidString.lowercased())] }
        let (data, response) = try await session.data(for: request(parts.url!, token: token, timeout: 6))
        if (response as? HTTPURLResponse)?.statusCode == 204 { return nil }
        try check(response)
        return try JSONDecoder().decode(ServerTrack.self, from: data)
    }

    func cancelDownloads() async { await downloads.cancelAndDrain() }

    func delete(_ source: RemoteTrackSource, token: String) async throws {
        var request = request(source.server.appendingPathComponent("api/music/tracks/\(source.id.uuidString.lowercased())"), token: token, timeout: 15)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 204 || status == 404 else { throw OnlineLibraryError.http(status) }
    }

    private func playlistWrite(server: URL, path: String, method: String, body: [String: Any], token: String) async throws -> ServerPlaylist {
        var request = request(server.appendingPathComponent("api/music/playlists" + path), token: token, timeout: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201 else { throw OnlineLibraryError.http(status) }
        return try JSONDecoder().decode(ServerPlaylist.self, from: data)
    }

    func uploadPlaylist(_ playlist: Playlist, trackIDs: [UUID], server: URL, token: String) async throws -> ServerPlaylist {
        let id = playlist.id.uuidString.lowercased()
        var list = try await playlistWrite(server: server, path: "", method: "POST", body: ["id": id, "name": playlist.name], token: token)
        for offset in stride(from: 0, to: trackIDs.count, by: 1000) {
            list = try await playlistWrite(server: server, path: "/\(id)/tracks", method: "POST", body: ["trackIds": trackIDs[offset..<min(offset + 1000, trackIDs.count)].map { $0.uuidString.lowercased() }], token: token)
        }
        var seen = Set<UUID>()
        let ids = trackIDs.filter { seen.insert($0).inserted }
        let desired = ids + list.trackIds.filter { !ids.contains($0) }
        if desired != list.trackIds {
            list = try await playlistWrite(server: server, path: "/\(id)/order", method: "PUT", body: ["trackIds": desired.map { $0.uuidString.lowercased() }, "expectedTrackIds": list.trackIds.map { $0.uuidString.lowercased() }], token: token)
        }
        return list
    }

    func upload(_ track: Track, server: URL, token: String) async throws -> ServerTrack {
        let boundary = "Sonora-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("sonora-upload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let preparation = Task.detached(priority: .utility) {
            let size = try track.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 128 * 1024 * 1024 else { throw OnlineLibraryError.message("单首歌曲应为 1 字节到 128 MB。") }
            FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }
            for (name, value) in [("title", track.title), ("artist", track.artist), ("album", track.album), ("duration", String(track.duration))] {
                try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(track.url.pathExtension.lowercased())\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: track.url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        }
        try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        var request = request(server.appendingPathComponent("api/music/tracks").appending(queryItems: [URLQueryItem(name: "reuseExisting", value: "true")]), token: token, timeout: 180)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201 else { throw OnlineLibraryError.http(status) }
        return try JSONDecoder().decode(ServerTrack.self, from: data)
    }

    func download(_ track: Track, token: String, onProgress: DownloadProgressHandler? = nil) async throws {
        guard let source = track.remoteSource else { return }
        try await downloads.download(to: track.url, totalBytes: source.size, onProgress: onProgress) { report in
            try await self.transfer(track, source: source, token: token, onProgress: report)
        }
    }

    private func transfer(_ track: Track, source: RemoteTrackSource, token: String,
                          onProgress: @escaping DownloadProgressHandler) async throws {
        let url = source.server.appendingPathComponent("api/music/tracks/\(source.id.uuidString.lowercased())/audio")
        let (temporary, response) = try await MusicFileDownload().run(session: session, request: request(url, token: token, timeout: 20)) { received in
            onProgress(TrackDownloadProgress(receivedBytes: received, totalBytes: source.size))
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(response)
        try Task.checkCancellation()
        let received = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        onProgress(TrackDownloadProgress(receivedBytes: received, totalBytes: source.size, phase: .verifying))
        let verification = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == source.size, digest == source.sha256 else {
                throw OnlineLibraryError.message("歌曲下载不完整，请重新连接服务器后重试。")
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: track.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: track.url, options: .atomic)
        }
        try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: { verification.cancel() }
    }
}

enum MusicCredentials {
    private static func query(_ server: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "studio.sonora.server-token",
         kSecAttrAccount as String: server.absoluteString]
    }

    static func read(server: URL) -> String {
        var attributes = query(server)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ token: String, server: URL) throws {
        let attributes = query(server)
        if token.isEmpty {
            let result = SecItemDelete(attributes as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else {
                throw OnlineLibraryError.message("无法更新钥匙串中的访问令牌。")
            }
            return
        }
        let values = [kSecValueData as String: Data(token.utf8)]
        var result = SecItemUpdate(attributes as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(attributes.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw OnlineLibraryError.message("无法把访问令牌保存到系统钥匙串。") }
    }
}
