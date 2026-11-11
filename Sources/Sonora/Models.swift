import Foundation

struct Track: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var url: URL
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var importedAt = Date()
    var isFavorite = false
    var artworkData: Data?
    var playCount = 0
    var remoteSource: RemoteTrackSource?

    var searchText: String { "\(title) \(artist) \(album) \(url.lastPathComponent)" }
    var fileExtension: String { url.pathExtension.uppercased() }
    var artistName: String {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未知艺术家" : name
    }
    var artistID: String { artistName.lowercased() }

    enum CodingKeys: String, CodingKey {
        case id, url, title, artist, album, duration, importedAt, isFavorite, artworkData, playCount, remoteSource
    }
}

extension Track {
    // Libraries saved before play statistics were introduced have no playCount key.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        url = try values.decode(URL.self, forKey: .url)
        title = try values.decode(String.self, forKey: .title)
        artist = try values.decode(String.self, forKey: .artist)
        album = try values.decode(String.self, forKey: .album)
        duration = try values.decode(Double.self, forKey: .duration)
        importedAt = try values.decode(Date.self, forKey: .importedAt)
        isFavorite = try values.decode(Bool.self, forKey: .isFavorite)
        artworkData = try values.decodeIfPresent(Data.self, forKey: .artworkData)
        playCount = max(0, try values.decodeIfPresent(Int.self, forKey: .playCount) ?? 0)
        remoteSource = try values.decodeIfPresent(RemoteTrackSource.self, forKey: .remoteSource)
    }
}

struct ArtistSummary: Identifiable {
    let id: String
    let name: String
    let tracks: [Track]
    let playCount: Int
    let artworkTrack: Track?

    init(id: String, name: String, tracks: [Track]) {
        self.id = id
        self.name = name
        self.tracks = tracks
        playCount = tracks.reduce(0) { $0 + $1.playCount }
        artworkTrack = tracks.first { $0.artworkData != nil }
    }
}

struct TrackStatistics {
    var duration: Double = 0
    var playCount = 0
    var favoriteCount = 0

    init(tracks: [Track]) {
        for track in tracks {
            duration += track.duration
            playCount += track.playCount
            if track.isFavorite { favoriteCount += 1 }
        }
    }
}

// Bound retained search/page results. FIFO eviction keeps reads allocation-free.
struct QueryCache<Key: Hashable, Value> {
    let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    subscript(key: Key) -> Value? { values[key] }

    mutating func insert(_ value: Value, for key: Key) {
        if values[key] == nil {
            if order.count >= capacity { values.removeValue(forKey: order.removeFirst()) }
            order.append(key)
        }
        values[key] = value
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}

// Preserve song identity and row numbers without copying every track into an
// enumerated array each time SwiftUI evaluates a lazy list.
struct NumberedTracks: RandomAccessCollection {
    struct Element: Identifiable {
        let index: Int
        let track: Track
        var id: UUID { track.id }
    }

    let tracks: [Track]
    var startIndex: Int { tracks.startIndex }
    var endIndex: Int { tracks.endIndex }
    func index(after i: Int) -> Int { i + 1 }
    func index(before i: Int) -> Int { i - 1 }
    subscript(index: Int) -> Element { Element(index: index, track: tracks[index]) }
}

enum ArtistSort: String, CaseIterable, Identifiable {
    case name, playCount, trackCount
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: "歌手名称"
        case .playCount: "播放次数"
        case .trackCount: "歌曲数量"
        }
    }
}

struct Playlist: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID] = []
}

enum LibrarySection: Hashable {
    case all, recent, favorites, artists, artist(String), playlist(UUID)

    var isArtistSection: Bool {
        switch self {
        case .artists, .artist: true
        default: false
        }
    }
}

struct TrackRevealRequest: Equatable, Sendable {
    let id = UUID()
    let trackID: UUID
}

enum TrackSort: String, CaseIterable, Identifiable {
    case added, title, artist, playCount
    var id: String { rawValue }
    var label: String {
        switch self {
        case .added: "添加时间"
        case .title: "歌曲名称"
        case .artist: "艺术家"
        case .playCount: "播放次数"
        }
    }
}

enum PlaybackMode: String, CaseIterable, Codable, Sendable {
    case sequential, loopAll, repeatOne, shuffle
    var symbol: String {
        switch self {
        case .sequential: "arrow.right"
        case .loopAll: "repeat"
        case .repeatOne: "repeat.1"
        case .shuffle: "shuffle"
        }
    }
    var label: String {
        switch self {
        case .sequential: "顺序播放"
        case .loopAll: "列表循环"
        case .repeatOne: "单曲循环"
        case .shuffle: "随机播放"
        }
    }
    var next: PlaybackMode {
        let modes = Self.allCases
        return modes[(modes.firstIndex(of: self)! + 1) % modes.count]
    }
}

/// A queue contains unique library IDs. The cursor always points at a valid item, or is nil.
struct PlaybackQueue: Codable, Equatable, Sendable {
    private(set) var ids: [UUID] = []
    private(set) var index: Int?
    var currentID: UUID? {
        guard let index, ids.indices.contains(index) else { return nil }
        return ids[index]
    }

    init(ids: [UUID] = [], startingAt id: UUID? = nil) {
        var seen = Set<UUID>()
        self.ids = ids.filter { seen.insert($0).inserted }
        index = id.flatMap { self.ids.firstIndex(of: $0) } ?? (self.ids.isEmpty ? nil : 0)
    }

    mutating func select(_ index: Int) {
        guard ids.indices.contains(index) else { return }
        self.index = index
    }

    @discardableResult
    mutating func advance(mode: PlaybackMode, automatic: Bool) -> Bool {
        guard let index, !ids.isEmpty else { return false }
        if automatic && mode == .repeatOne { return true }
        if index + 1 < ids.count {
            self.index = index + 1
            return true
        }
        if mode == .loopAll || mode == .shuffle {
            self.index = 0
            return true
        }
        return false
    }

    @discardableResult
    mutating func retreat(mode: PlaybackMode) -> Bool {
        guard let index, !ids.isEmpty else { return false }
        if index > 0 {
            self.index = index - 1
            return true
        }
        if mode == .loopAll {
            self.index = ids.count - 1
            return true
        }
        return false
    }

    mutating func insertNext(_ id: UUID) {
        guard currentID != id else { return }
        let current = currentID
        ids.removeAll { $0 == id }
        index = current.flatMap { ids.firstIndex(of: $0) }
        let insertion = index.map { $0 + 1 } ?? 0
        ids.insert(id, at: insertion)
        if index == nil { index = 0 }
    }

    mutating func remove(_ removed: Set<UUID>) {
        let current = currentID
        let oldIndex = index ?? 0
        // Prefer the following surviving song if the current one is removed.
        let successor = ids.dropFirst(oldIndex + 1).first { !removed.contains($0) }
        ids.removeAll { removed.contains($0) }
        if let current, !removed.contains(current) {
            index = ids.firstIndex(of: current)
        } else if let successor {
            index = ids.firstIndex(of: successor)
        } else {
            index = ids.isEmpty ? nil : ids.count - 1
        }
    }

    mutating func shuffleUpcoming() {
        guard let index, index + 1 < ids.count else { return }
        let remaining = ids[(index + 1)...].shuffled()
        ids.replaceSubrange((index + 1)..., with: remaining)
    }

    mutating func clearUpcoming() {
        guard let index else { return }
        ids = Array(ids.prefix(index + 1))
    }

    func validated(against validIDs: Set<UUID>) -> PlaybackQueue {
        PlaybackQueue(ids: ids.filter { validIDs.contains($0) }, startingAt: currentID)
    }
}

struct LibrarySnapshot: Codable, Equatable, Sendable {
    var version = 1
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    var queue = PlaybackQueue()
    var mode = PlaybackMode.loopAll
    var volume: Float = 0.7
    var elapsed: Double = 0

    func sanitized() -> LibrarySnapshot {
        var copy = self
        var seen = Set<UUID>()
        copy.tracks = tracks.filter { seen.insert($0.id).inserted }
        let valid = Set(copy.tracks.map(\.id))
        copy.queue = queue.validated(against: valid)
        copy.playlists = playlists.map { list in
            var list = list
            var unique = Set<UUID>()
            list.trackIDs = list.trackIDs.filter { valid.contains($0) && unique.insert($0).inserted }
            return list
        }
        copy.volume = volume.isFinite ? min(1, max(0, volume)) : 0.7
        copy.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        return copy
    }
}

enum LibraryPersistence {
    static var defaultURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("Sonora", isDirectory: true).appendingPathComponent("library.json")
    }

    static func load(from url: URL) throws -> LibrarySnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return LibrarySnapshot() }
        let state = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw CocoaError(.fileReadUnknown) }
        return state.sanitized()
    }

    static func save(_ state: LibrarySnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }
}

/// Serialize background writes and the final synchronous flush on one queue so
/// an older autosave can never overwrite the snapshot saved when quitting.
final class LibraryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "studio.sonora.library-writer", qos: .utility)
    private let write: @Sendable (LibrarySnapshot, URL) throws -> Void

    init(write: @escaping @Sendable (LibrarySnapshot, URL) throws -> Void = {
        try LibraryPersistence.save($0, to: $1)
    }) {
        self.write = write
    }

    func save(_ snapshot: LibrarySnapshot, to url: URL,
              completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            completion(Result { try self.write(snapshot, url) })
        }
    }

    func flush(_ snapshot: LibrarySnapshot, to url: URL) throws {
        try queue.sync { try write(snapshot, url) }
    }
}

func clockText(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

func durationText(_ seconds: Double) -> String {
    let minutes = Int(max(0, seconds.isFinite ? seconds : 0)) / 60
    if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
    return "\(minutes) 分钟"
}
