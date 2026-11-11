import Foundation
import CryptoKit
import Security

struct RemoteTrackSource: Codable, Equatable, Sendable {
    let server: URL
    let id: UUID
    let sha256: String
    let size: Int64
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
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
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
            throw OnlineLibraryError.message("服务器歌曲信息无效，已使用离线模式。")
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
final class MusicRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct OnlineMusicClient: Sendable {
    let session: URLSession
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
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode
            throw OnlineLibraryError.message(code == 401 || code == 403
                ? "服务器认证失败，请在连接设置中检查访问令牌。当前使用离线模式。"
                : "服务器暂不可用，当前使用离线模式。")
        }
    }

    func list(server: URL, token: String) async throws -> [ServerTrack] {
        let (data, response) = try await session.data(for: request(server.appendingPathComponent("api/music/tracks"), token: token, timeout: 6))
        try check(response)
        return try JSONDecoder().decode([ServerTrack].self, from: data)
    }

    func download(_ track: Track, token: String) async throws {
        guard let source = track.remoteSource else { return }
        let url = source.server.appendingPathComponent("api/music/tracks/\(source.id.uuidString.lowercased())/audio")
        let (temporary, response) = try await session.download(for: request(url, token: token, timeout: 20))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(response)
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == source.size, digest == source.sha256 else {
                throw OnlineLibraryError.message("歌曲下载不完整，请重新连接服务器后重试。")
            }
            try FileManager.default.createDirectory(at: track.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: track.url, options: .atomic)
        }.value
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
