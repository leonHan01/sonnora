import AppKit
import AVFoundation
import Combine
import MediaPlayer
import UniformTypeIdentifiers

enum PlaylistEditor: Identifiable {
    case create, createAdding(UUID), rename(UUID)
    var id: String {
        switch self {
        case .create: "create"
        case .createAdding(let id): "create-adding-\(id.uuidString)"
        case .rename(let id): id.uuidString
        }
    }
}

struct PlayerNotice: Equatable {
    var message: String
    var isError = false
}

@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var elapsed: Double = 0
}

@MainActor
final class PlaybackDownloadProgress: ObservableObject {
    struct Active: Equatable {
        let trackID: UUID
        var progress: TrackDownloadProgress
    }
    @Published private(set) var active: Active?

    func begin(_ track: Track) {
        active = Active(trackID: track.id, progress: TrackDownloadProgress(receivedBytes: 0, totalBytes: track.remoteSource?.size ?? 0))
    }

    func update(_ progress: TrackDownloadProgress, for id: UUID) {
        guard let active, active.trackID == id,
              progress.receivedBytes >= active.progress.receivedBytes,
              progress.phase.rawValue >= active.progress.phase.rawValue else { return }
        let next = Active(trackID: id, progress: progress)
        if next != active { self.active = next }
    }

    func reset() { if active != nil { active = nil } }
}

@MainActor
final class PlaybackVolume: ObservableObject {
    @Published fileprivate(set) var value: Float = 0.7
}

@MainActor
final class TrackSelection: ObservableObject {
    @Published fileprivate(set) var id: UUID?
}

@MainActor
final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var tracks: [Track] = [] {
        didSet { invalidateLibraryQueries() }
    }
    @Published var playlists: [Playlist] = [] {
        didSet {
            sectionCache.removeAll()
            trackQueryCache.removeAll()
        }
    }
    @Published private(set) var onlinePlaylistCache: [String: [ServerPlaylist]] = [:] {
        didSet { sectionCache.removeAll(); trackQueryCache.removeAll() }
    }
    @Published private(set) var onlinePlaylistMessage = ""
    private var configuredServer: URL { (try? OnlineSettings.serverURL(onlineSettings.server)) ?? URL(string: "https://invalid.invalid")! }
    var onlinePlaylists: [ServerPlaylist] { onlinePlaylistCache[onlineSettings.server] ?? [] }
    var isOnlinePlaylistSection: Bool { if case .onlinePlaylist = section { return true }; return false }

    @Published var section = LibrarySection.all
    @Published var search = ""
    @Published var sort = TrackSort.added
    let trackSelection = TrackSelection()
    var selectedTrackID: UUID? {
        get { trackSelection.id }
        set {
            if trackSelection.id != newValue { trackSelection.id = newValue }
        }
    }
    @Published private(set) var trackRevealRequest: TrackRevealRequest?
    @Published var queue = PlaybackQueue() {
        didSet { queuedTrackCache = nil; refreshUpcomingCache() }
    }
    @Published var mode = PlaybackMode.loopAll {
        didSet { if mode != oldValue { refreshUpcomingCache() } }
    }
    @Published var isPlaying = false {
        didSet { if isPlaying != oldValue { refreshUpcomingCache() } }
    }
    let playbackProgress = PlaybackProgress()
    var elapsed: Double {
        get { playbackProgress.elapsed }
        set { playbackProgress.elapsed = newValue }
    }
    @Published var playbackDuration: Double = 0
    let playbackVolume = PlaybackVolume()
    var volume: Float {
        get { playbackVolume.value }
        set {
            let value = newValue.isFinite ? min(1, max(0, newValue)) : 0.7
            guard value != playbackVolume.value else { return }
            playbackVolume.value = value
            audioPlayer?.volume = value
            scheduleSave()
        }
    }
    @Published var showQueue = false
    @Published var isMiniMode = false
    @Published var isImporting = false
    @Published var importProgress = ""
    @Published var notice: PlayerNotice?
    @Published var playlistEditor: PlaylistEditor?
    @Published var deletionTrack: Track?
    @Published private(set) var isManagingStorage = false
    @Published private(set) var storageMessage = ""
    @Published var showConnectionSettings = false
    @Published private(set) var onlineSettings = OnlineSettings()
    @Published private(set) var isOnline = false
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionMessage = "离线模式 · 本地与已缓存音乐"
    @Published private(set) var loadingTrackID: UUID?
    let downloadProgress = PlaybackDownloadProgress()
    @Published private(set) var isRadioActive = false
    @Published private(set) var isRadioLoading = false
    @Published private(set) var radioTrackID: UUID?
    @Published private(set) var radioMessage = "让电台为你挑一首，遇见下一段喜欢的旋律。"

    private var radioTask: Task<Void, Never>?
    private var radioAttempt = UUID()
    private(set) var radioUpcomingIDs: [UUID] = []
    private var upcomingCacheTask: Task<Void, Never>?
    private var upcomingCacheAttempt = UUID()
    private struct UpcomingCachePlan: Equatable {
        let currentID: UUID
        let queuedIDs: [UUID]
        let radio: Bool
        let server: URL
    }
    private var upcomingCachePlan: UpcomingCachePlan?
    private var hasLoadedOnlineCatalog = false

    private let musicClient: OnlineMusicClient
    private var connectionToken = ""
    private var connectionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var audioDownloadTask: Task<Void, Never>?
    private var connectionAttempt = UUID()
    private var playbackAttempt = UUID()
    private var startedOnlineMode = false
    private var onlineIDs = Set<UUID>()
    private var availableTrackCache: [Track]?

    private var audioPlayer: AVAudioPlayer?
    private let storageURL: URL
    private let libraryWriter: LibraryWriter
    private var saveRevision = 0
    private var saveTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var pendingImports: [URL] = []
    private var keyMonitor: Any?
    private var lastAudibleVolume: Float = 0.7
    private var lastNowPlayingSecond = -1
    private var nowPlayingTrackID: UUID?
    private let systemControlsEnabled: Bool
    private var hasCountedCurrentPlayback = false

    private struct TrackQuery: Hashable {
        let section: LibrarySection
        let search: String
        let sort: TrackSort
    }
    private struct ArtistQuery: Hashable {
        let search: String
        let sort: ArtistSort
    }
    private struct SectionContent {
        let tracks: [Track]
        let statistics: TrackStatistics
    }
    private var trackPositions: [UUID: Int]?
    private var artistCache: [ArtistSummary]?
    private var statisticsCache: TrackStatistics?
    private var queuedTrackCache: [Track]?
    private var sectionCache = QueryCache<LibrarySection, SectionContent>(capacity: 8)
    private var trackQueryCache = QueryCache<TrackQuery, [Track]>(capacity: 8)
    private var artistQueryCache = QueryCache<ArtistQuery, [ArtistSummary]>(capacity: 4)

    private func invalidateLibraryQueries() {
        availableTrackCache = nil
        trackPositions = nil
        artistCache = nil
        statisticsCache = nil
        queuedTrackCache = nil
        sectionCache.removeAll()
        trackQueryCache.removeAll()
        artistQueryCache.removeAll()
    }

    private func position(of id: UUID) -> Int? {
        if trackPositions == nil {
            var positions: [UUID: Int] = [:]
            positions.reserveCapacity(tracks.count)
            for index in tracks.indices where positions[tracks[index].id] == nil {
                positions[tracks[index].id] = index
            }
            trackPositions = positions
        }
        return trackPositions?[id]
    }

    func track(for id: UUID?) -> Track? {
        guard let id, let index = position(of: id) else { return nil }
        return tracks[index]
    }

    var currentTrack: Track? { track(for: queue.currentID) }
    var availableTracks: [Track] {
        if let availableTrackCache { return availableTrackCache }
        let result = tracks.filter { track in
            track.remoteSource == nil || (isOnline && onlineIDs.contains(track.id)) || FileManager.default.fileExists(atPath: track.url.path)
        }
        availableTrackCache = result
        return result
    }
    var libraryStatistics: TrackStatistics {
        if let statisticsCache { return statisticsCache }
        let result = TrackStatistics(tracks: availableTracks)
        statisticsCache = result
        return result
    }
    var artists: [ArtistSummary] {
        if let artistCache { return artistCache }
        let result = Dictionary(grouping: availableTracks, by: \.artistID).map { id, songs in
            ArtistSummary(id: id, name: songs[0].artistName, tracks: songs)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        artistCache = result
        return result
    }
    var visibleArtists: [ArtistSummary] {
        sortedVisibleArtists(by: .name)
    }
    func sortedVisibleArtists(by sort: ArtistSort) -> [ArtistSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ArtistQuery(search: query, sort: sort)
        if let cached = artistQueryCache[key] { return cached }
        var result = query.isEmpty ? artists : artists.filter { $0.name.localizedStandardContains(query) }
        if sort != .name {
            result.sort {
                switch sort {
                case .name: break
                case .playCount:
                    if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
                case .trackCount:
                    if $0.tracks.count != $1.tracks.count { return $0.tracks.count > $1.tracks.count }
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        artistQueryCache.insert(result, for: key)
        return result
    }
    var sectionTitle: String {
        switch section {
        case .all: "全部音乐"
        case .recent: "最近添加"
        case .favorites: "我的收藏"
        case .radio: "我的电台"
        case .artists: "所有歌手"
        case .playlists: "我的歌单"
        case .onlinePlaylists: "在线歌单"
        case .artist(let id): artists.first { $0.id == id }?.name ?? "歌手"
        case .playlist(let id): playlists.first { $0.id == id }?.name ?? "歌单"
        case .onlinePlaylist(let id): onlinePlaylists.first { $0.id == id }?.name ?? "在线歌单"
        }
    }
    var sectionSubtitle: String {
        switch section {
        case .all: "让喜欢的旋律，留在此刻。"
        case .recent: "新发现的声音，值得再听一遍。"
        case .favorites: "每一次心动，都有迹可循。"
        case .radio: "一首接一首，把下一次心动交给电台。"
        case .artists: "从一个名字，听见更多喜欢。"
        case .playlists: "把喜欢的声音，整理成属于自己的歌单。"
        case .onlinePlaylists: isOnline ? "来自服务器的共享歌单，选择一张开始聆听。" : "已保存的在线歌单，离线时可收听其中已缓存的歌曲。"
        case .artist: "这位歌手在你曲库中的全部歌曲。"
        case .playlist: "属于你的音乐片刻。"
        case .onlinePlaylist: isOnline ? "来自服务器的在线歌单 · 选择歌曲或播放全部。" : "离线收听 · 仅显示这张在线歌单中已缓存的歌曲。"
        }
    }
    var sectionTracks: [Track] { sectionContent.tracks }
    var sectionStatistics: TrackStatistics { sectionContent.statistics }

    private var sectionContent: SectionContent {
        if let cached = sectionCache[section] { return cached }
        let result: [Track]
        switch section {
        case .all: result = availableTracks
        case .recent: result = Array(availableTracks.sorted { $0.importedAt > $1.importedAt }.prefix(50))
        case .favorites: result = availableTracks.filter(\.isFavorite)
        case .artists, .radio, .playlists, .onlinePlaylists: result = []
        case .artist(let id): result = artists.first { $0.id == id }?.tracks ?? []
        case .onlinePlaylist(let id):
            let ids = onlinePlaylists.first { $0.id == id }?.trackIds ?? []
            var songs: [UUID: Track] = [:]
            for song in availableTracks where song.source(on: configuredServer) != nil {
                if let source = song.source(on: configuredServer) { songs[source.id] = song }
            }
            result = ids.compactMap { songs[$0] }
        case .playlist(let id):
            let ids = playlists.first { $0.id == id }?.trackIDs ?? []
            let available = Set(availableTracks.map(\.id))
            result = ids.filter { available.contains($0) }.compactMap { track(for: $0) }
        }
        let content = SectionContent(tracks: result, statistics: TrackStatistics(tracks: result))
        sectionCache.insert(content, for: section)
        return content
    }
    var visibleTracks: [Track] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = TrackQuery(section: section, search: query, sort: sort)
        if let cached = trackQueryCache[key] { return cached }
        // Reuse the sorted section as the user types; filtering preserves its order.
        var result = sortedSectionTracks
        if !query.isEmpty { result = result.filter { $0.searchText.localizedStandardContains(query) } }
        trackQueryCache.insert(result, for: key)
        return result
    }

    private var sortedSectionTracks: [Track] {
        // Shared playlists always use their saved server order. Library sorting
        // remains available in local views; shuffle is an explicit playback action.
        if isOnlinePlaylistSection { return sectionTracks }
        let key = TrackQuery(section: section, search: "", sort: sort)
        if let cached = trackQueryCache[key] { return cached }
        var result = sectionTracks
        switch sort {
        case .added:
            if case .playlist = section { break }
            if case .onlinePlaylist = section { break }
            result.sort { $0.importedAt > $1.importedAt }
        case .title: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: result.sort { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .playCount:
            result.sort {
                if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        trackQueryCache.insert(result, for: key)
        return result
    }
    var queuedTracks: [Track] {
        if let queuedTrackCache { return queuedTrackCache }
        let result = queue.ids.compactMap { track(for: $0) }
        queuedTrackCache = result
        return result
    }

    init(storageURL: URL = LibraryPersistence.defaultURL, enableSystemControls: Bool = true,
         libraryWriter: LibraryWriter = LibraryWriter(), musicClient: OnlineMusicClient = OnlineMusicClient()) {
        self.storageURL = storageURL
        self.libraryWriter = libraryWriter
        self.systemControlsEnabled = enableSystemControls
        self.musicClient = musicClient
        super.init()
        if let data = try? Data(contentsOf: connectionSettingsURL),
           let settings = try? JSONDecoder().decode(OnlineSettings.self, from: data) {
            onlineSettings = settings
        }
        do {
            let state = try LibraryPersistence.load(from: storageURL)
            tracks = state.tracks
            playlists = state.playlists
            onlinePlaylistCache = state.onlinePlaylists
            queue = state.queue
            mode = state.mode
            volume = state.volume
            if volume > 0 { lastAudibleVolume = volume }
            if queue.currentID != nil { loadCurrent(autoplay: false, at: state.elapsed) }
        } catch {
            // Keep the original data before allowing a fresh library to be saved.
            let backup = storageURL.deletingPathExtension().appendingPathExtension("recovery-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.copyItem(at: storageURL, to: backup)
                notice = PlayerNotice(message: "曲库读取失败，原文件已备份为 \(backup.lastPathComponent)。可重新导入音乐。", isError: true)
            } catch {
                notice = PlayerNotice(message: "曲库读取失败。请先检查文件权限：\(storageURL.path)", isError: true)
                // Do not overwrite a library which could not be backed up.
                persistenceAllowed = false
            }
        }
        if enableSystemControls { installSystemControls() }
    }

    private var persistenceAllowed = true

    private var connectionSettingsURL: URL { storageURL.deletingLastPathComponent().appendingPathComponent("online-settings.json") }
    var musicCacheURL: URL { storageURL.deletingLastPathComponent().appendingPathComponent("online-audio", isDirectory: true) }

    func startOnlineMode() {
        guard !startedOnlineMode else { return }
        startedOnlineMode = true
        if let server = try? OnlineSettings.serverURL(onlineSettings.server) { connectionToken = MusicCredentials.read(server: server) }
        reconnect()
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                if self.onlineSettings.enabled && !self.isConnecting { self.reconnect() }
            }
        }
    }

    func saveConnectionSettings(server: String, enabled: Bool, token: String, clearToken: Bool) throws {
        guard !isManagingStorage else { throw OnlineLibraryError.message("请等待上传或清理完成。") }
        let url = try OnlineSettings.serverURL(server)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count <= 1000, !token.contains(where: { $0.isNewline }) else {
            throw OnlineLibraryError.message("访问令牌格式无效。")
        }
        if clearToken || !token.isEmpty { try MusicCredentials.save(clearToken ? "" : token, server: url) }
        let settings = OnlineSettings(enabled: enabled, server: url.absoluteString)
        try FileManager.default.createDirectory(at: connectionSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: connectionSettingsURL, options: .atomic)
        endRadio()
        hasLoadedOnlineCatalog = false
        onlineSettings = settings
        onlinePlaylistMessage = ""
        if isOnlinePlaylistSection { section = .all }
        connectionToken = MusicCredentials.read(server: url)
        useOfflineMode(message: "离线模式 · 本地与已缓存音乐")
        reconnect()
    }

    func reconnect() {
        guard !isManagingStorage else { return }
        connectionTask?.cancel()
        let attempt = UUID()
        connectionAttempt = attempt
        guard onlineSettings.enabled else {
            isConnecting = false
            useOfflineMode(message: "离线模式 · 已关闭在线连接")
            return
        }
        guard let server = try? OnlineSettings.serverURL(onlineSettings.server) else {
            useOfflineMode(message: "服务器地址无效，当前使用离线模式。")
            return
        }
        isConnecting = true
        let token = connectionToken
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if connectionAttempt == attempt { isConnecting = false } }
            do {
                let records = try await musicClient.list(server: server, token: token)
                let incoming = try records.map { try $0.track(server: server, cacheRoot: self.musicCacheURL) }
                try Task.checkCancellation()
                guard connectionAttempt == attempt else { return }
                try await synchronizeCatalog(incoming, server: server)
                hasLoadedOnlineCatalog = true
                isOnline = true
                connectionMessage = "在线模式 · \(incoming.count) 首服务器歌曲"
                invalidateLibraryQueries()
                refreshUpcomingCache()
                // A missing playlist feature must not disconnect a healthy music catalog.
                do {
                    let lists = try await musicClient.playlists(server: server, token: token)
                    try Task.checkCancellation()
                    guard connectionAttempt == attempt else { return }
                    mergeOnlinePlaylists(lists, server: server)
                    onlinePlaylistMessage = ""
                } catch {
                    guard !Task.isCancelled, connectionAttempt == attempt else { return }
                    onlinePlaylistMessage = "在线歌单暂时无法更新，保留上次列表。" + ((error as? OnlineLibraryError)?.localizedDescription ?? "请稍后刷新。")
                }
            } catch {
                guard !Task.isCancelled, connectionAttempt == attempt else { return }
                useOfflineMode(message: (error as? OnlineLibraryError)?.localizedDescription ?? "连接不上服务器，当前使用离线模式。")
                if isRadioActive && currentTrack == nil && !isRadioLoading { playOfflineRadio() }
            }
        }
    }

    // Partial radio responses merge without evicting other songs. Full catalogs
    // additionally reconcile deleted songs through synchronizeCatalog().
    func mergeOnlineTracks(_ incoming: [Track], replacingOnlineIDs: Bool = true) {
        var merged = tracks
        var ids = Set<UUID>()
        for var song in incoming {
            if let index = merged.firstIndex(where: { $0.id == song.id || (song.remoteSource != nil && $0.source(on: song.remoteSource!.server)?.id == song.remoteSource?.id) }) {
                let existing = merged[index]
                song.id = existing.id
                if existing.remoteSource == nil || existing.remoteSource?.sha256 == song.remoteSource?.sha256 { song.url = existing.url }
                else if let source = song.remoteSource { song.url = musicCacheURL.appendingPathComponent("\(existing.id.uuidString)-\(source.sha256).\(song.url.pathExtension)") }
                song.isFavorite = existing.isFavorite
                song.playCount = existing.playCount
                song.artworkData = existing.artworkData
                song.cloudSources = existing.cloudSources
                if existing.remoteSource == nil { song.remoteSource = nil }
                if song.duration == 0 { song.duration = existing.duration }
                if song.artist == "未知艺术家" { song.artist = existing.artist }
                if song.album == "未知专辑" { song.album = existing.album }
                merged[index] = song
            } else { merged.append(song) }
            ids.insert(song.id)
        }
        if replacingOnlineIDs { onlineIDs = ids } else { onlineIDs.formUnion(ids) }
        if tracks != merged { tracks = merged; scheduleSave() }
    }

    func synchronizeCatalog(_ incoming: [Track], server: URL) async throws {
        let present = Set(incoming.compactMap { $0.remoteSource?.id })
        let removed = tracks.filter { $0.source(on: server).map { !present.contains($0.id) } ?? false }
        if !removed.isEmpty {
            guard !isManagingStorage else { throw CancellationError() }
            isManagingStorage = true
            defer { isManagingStorage = false }
            await prepareStorageChange(stopping: Set(removed.filter { $0.remoteSource != nil }.map(\.id)), cancelConnection: false)
            for song in removed {
                if let source = song.source(on: server) { try removeSourceCaches(source) }
                if song.remoteSource != nil { try removeManagedCache(song); forgetTrack(song.id) }
                else if let index = position(of: song.id) { tracks[index].cloudSources.removeAll { $0.server == server } }
            }
            ArtworkCache.clear()
        }
        try Task.checkCancellation()
        mergeOnlineTracks(incoming)
    }

    func mergeOnlinePlaylists(_ lists: [ServerPlaylist], server: URL) {
        onlinePlaylistCache[server.absoluteString] = lists
        if server.absoluteString == onlineSettings.server,
           case .onlinePlaylist(let id) = section, !lists.contains(where: { $0.id == id }) {
            section = .onlinePlaylists
        }
        scheduleSave()
    }

    func openOnlineManagement() {
        if let server = try? OnlineSettings.serverURL(onlineSettings.server) { NSWorkspace.shared.open(server.appendingPathComponent("music.html")) }
    }

    func useOfflineMode(message: String) {
        cancelUpcomingCache()
        radioUpcomingIDs.removeAll { id in
            guard let song = track(for: id) else { return true }
            return !FileManager.default.fileExists(atPath: song.url.path)
        }
        isOnline = false
        connectionMessage = message
        invalidateLibraryQueries()
        // Drop unreachable queue entries while preserving the current local song.
        let oldID = queue.currentID
        let wasPlaying = isPlaying
        queue = queue.validated(against: Set(availableTracks.map(\.id)))
        if oldID != queue.currentID { loadCurrent(autoplay: wasPlaying) }
        scheduleSave()
    }

    private func cancelUpcomingCache() {
        upcomingCacheAttempt = UUID()
        upcomingCacheTask?.cancel()
        upcomingCacheTask = nil
        upcomingCachePlan = nil
    }

    private func refreshUpcomingCache() {
        guard !isManagingStorage, isPlaying, isOnline, loadingTrackID == nil, let currentID = queue.currentID,
              let server = try? OnlineSettings.serverURL(onlineSettings.server) else {
            cancelUpcomingCache()
            return
        }
        let radio = isRadioActive
        let queuedIDs = queue.upcomingIDs(mode: mode)
        let plan = UpcomingCachePlan(currentID: currentID, queuedIDs: queuedIDs, radio: radio, server: server)
        // Periodic catalog refreshes must not restart a slow, valid download.
        if upcomingCacheTask != nil, upcomingCachePlan == plan { return }
        cancelUpcomingCache()
        upcomingCachePlan = plan
        let attempt = upcomingCacheAttempt
        let token = connectionToken
        upcomingCacheTask = Task(priority: .utility) { [weak self] in
            guard let self, !Task.isCancelled, upcomingCacheAttempt == attempt else { return }
            defer {
                if upcomingCacheAttempt == attempt {
                    upcomingCacheTask = nil
                    upcomingCachePlan = nil
                }
            }
            if radio {
                if !hasLoadedOnlineCatalog {
                    do {
                        let records = try await musicClient.list(server: server, token: token)
                        try Task.checkCancellation()
                        guard upcomingCacheAttempt == attempt else { return }
                        let incoming = try records.map { try $0.track(server: server, cacheRoot: self.musicCacheURL) }
                        mergeOnlineTracks(incoming)
                        hasLoadedOnlineCatalog = true
                    } catch { return } // Look-ahead failures never interrupt the current song.
                }
                prepareRadioUpcoming(after: currentID, server: server)
            }
            let ids = radio ? radioUpcomingIDs : queuedIDs
            for id in ids {
                guard !Task.isCancelled, upcomingCacheAttempt == attempt,
                      let song = track(for: id) else { return }
                guard onlineIDs.contains(id), song.remoteSource?.server == server,
                      !FileManager.default.fileExists(atPath: song.url.path) else { continue }
                do {
                    try await musicClient.download(song, token: token)
                    try Task.checkCancellation()
                    guard upcomingCacheAttempt == attempt else { return }
                    // Metadata is optional here; validated audio is already cached.
                    // Reading tags never starts playback or changes play counts.
                    let metadata = try? await TrackImporter.read(song.url)
                    try Task.checkCancellation()
                    guard upcomingCacheAttempt == attempt else { return }
                    if let metadata {
                        applyDownloadedMetadata(metadata, to: song.id)
                    }
                    invalidateLibraryQueries()
                    scheduleSave()
                } catch {
                    if Task.isCancelled { return }
                    // Leave the next song eligible for a normal playback retry.
                }
            }
        }
    }

    private func prepareRadioUpcoming(after currentID: UUID, server: URL) {
        let candidates = tracks.filter { onlineIDs.contains($0.id) && $0.source(on: server) != nil }
        let valid = Set(candidates.map(\.id))
        radioUpcomingIDs.removeAll { !valid.contains($0) }
        var used = Set(radioUpcomingIDs + [currentID])
        while radioUpcomingIDs.count < 3 {
            let last = radioUpcomingIDs.last ?? currentID
            let unseen = candidates.filter { !used.contains($0.id) }
            let alternatives = unseen.isEmpty ? candidates.filter { $0.id != last } : unseen
            guard let song = (alternatives.isEmpty ? candidates : alternatives).randomElement() else { break }
            radioUpcomingIDs.append(song.id)
            used.insert(song.id)
        }
    }

    private func applyDownloadedMetadata(_ metadata: Track, to id: UUID) {
        guard let index = position(of: id) else { return }
        tracks[index].duration = metadata.duration
        tracks[index].artworkData = metadata.artworkData
        if tracks[index].artist == "未知艺术家" { tracks[index].artist = metadata.artist }
        if tracks[index].album == "未知专辑" { tracks[index].album = metadata.album }
    }

    private func cancelAudioDownload() {
        playbackAttempt = UUID()
        audioDownloadTask?.cancel()
        audioDownloadTask = nil
        loadingTrackID = nil
        downloadProgress.reset()
    }

    private func downloadForPlayback(_ track: Track, at position: Double) {
        guard isOnline, onlineIDs.contains(track.id), track.remoteSource?.server == configuredServer else {
            useOfflineMode(message: "连接不上服务器，当前使用离线模式。")
            showNotice("这首歌曲尚未缓存，请选择本地音乐或重新连接服务器。", error: true)
            if isRadioActive { playOfflineRadio() }
            return
        }
        let attempt = UUID()
        playbackAttempt = attempt
        loadingTrackID = track.id
        downloadProgress.begin(track)
        let token = connectionToken
        audioDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await musicClient.download(track, token: token) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, playbackAttempt == attempt, loadingTrackID == track.id else { return }
                        downloadProgress.update(progress, for: track.id)
                    }
                }
                try Task.checkCancellation()
                guard playbackAttempt == attempt, queue.currentID == track.id else { return }
                downloadProgress.update(TrackDownloadProgress(receivedBytes: track.remoteSource?.size ?? 0,
                                                              totalBytes: track.remoteSource?.size ?? 0, phase: .preparing), for: track.id)
                let metadata = try await TrackImporter.read(track.url)
                try Task.checkCancellation()
                guard playbackAttempt == attempt, queue.currentID == track.id else { return }
                applyDownloadedMetadata(metadata, to: track.id)
                loadCurrent(autoplay: true, at: position)
            } catch {
                guard !Task.isCancelled, playbackAttempt == attempt else { return }
                loadingTrackID = nil
                downloadProgress.reset()
                // Do not retain a corrupt/incomplete download as an offline song.
                try? FileManager.default.removeItem(at: track.url)
                let message = (error as? OnlineLibraryError)?.localizedDescription ?? "歌曲下载或解析失败，请重试或换一首。"
                if OnlineLibraryError.requiresOfflineMode(error) { useOfflineMode(message: message + " 当前使用离线模式。") }
                else { connectionMessage = message }
                showNotice("无法播放《\(track.title)》：" + message, error: true)
                if isRadioActive { playOfflineRadio() }
            }
        }
    }

    @Published private(set) var radioUsesLocalSongs = false

    var radioTrack: Track? { track(for: radioTrackID) }
    var isRadioBuffering: Bool { isRadioLoading || (isRadioActive && loadingTrackID != nil) }

    func showRadio() {
        section = .radio
        search = ""
        selectedTrackID = nil
        if !isRadioActive { nextRadioTrack() }
    }

    private func cancelRadioRequest() {
        if isRadioLoading { radioMessage = "已取消加载，可以继续收听或换一首。" }
        radioAttempt = UUID()
        radioTask?.cancel()
        radioTask = nil
        isRadioLoading = false
    }

    private func endRadio() {
        cancelRadioRequest()
        cancelUpcomingCache()
        radioUpcomingIDs = []
        isRadioActive = false
    }

    func nextRadioTrack() {
        guard !isManagingStorage else { return }
        let wasActive = isRadioActive
        cancelRadioRequest()
        cancelAudioDownload()
        let previousSource = radioTrack?.source(on: configuredServer)
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        elapsed = 0
        playbackDuration = 0
        queue = PlaybackQueue()
        isRadioActive = true
        if !wasActive { radioUpcomingIDs = [] }
        updateNowPlaying()
        scheduleSave()
        while !radioUpcomingIDs.isEmpty {
            let id = radioUpcomingIDs.removeFirst()
            guard let song = track(for: id),
                  isOnline ? (onlineIDs.contains(id) && song.source(on: configuredServer) != nil)
                           : FileManager.default.fileExists(atPath: song.url.path) else { continue }
            activateRadioTrack(song)
            return
        }
        guard onlineSettings.enabled, isOnline || !wasActive,
              let server = try? OnlineSettings.serverURL(onlineSettings.server) else {
            playOfflineRadio()
            return
        }
        let excluded = previousSource?.server == server ? previousSource?.id : nil
        let attempt = UUID()
        radioAttempt = attempt
        isRadioLoading = true
        radioMessage = "正在为你寻找下一首…"
        let token = connectionToken
        radioTask = Task { [weak self] in
            guard let self else { return }
            defer { if radioAttempt == attempt { isRadioLoading = false } }
            do {
                let record = try await musicClient.radio(server: server, token: token, excluding: excluded)
                try Task.checkCancellation()
                guard radioAttempt == attempt else { return }
                isOnline = true
                connectionMessage = "在线模式 · 电台已连接"
                invalidateLibraryQueries()
                guard let record else {
                    isRadioActive = false
                    radioMessage = "服务器还没有可播放的歌曲，请先在歌曲管理页上传音乐。"
                    return
                }
                let song = try record.track(server: server, cacheRoot: musicCacheURL)
                mergeOnlineTracks([song], replacingOnlineIDs: false)
                isOnline = true
                connectionMessage = "在线模式 · 电台收听中"
                invalidateLibraryQueries()
                let linked = tracks.first { $0.source(on: server)?.id == record.id } ?? song
                activateRadioTrack(linked)
            } catch {
                guard !Task.isCancelled, radioAttempt == attempt else { return }
                let message: String
                if case .http(let code) = error as? OnlineLibraryError, code == 404 || code == 405 {
                    message = "服务器电台接口未启用（HTTP \(code)），请更新服务端。"
                } else { message = (error as? OnlineLibraryError)?.localizedDescription ?? "连接不上服务器。" }
                if OnlineLibraryError.requiresOfflineMode(error) { useOfflineMode(message: message + " 当前使用离线模式。") }
                else { connectionMessage = message }
                playOfflineRadio()
                if isOnline { radioMessage = message + " 已使用本地电台，可以再次点击换一首重试。" }
            }
        }
    }

    private func activateRadioTrack(_ song: Track) {
        radioUsesLocalSongs = !isOnline || song.source(on: configuredServer) == nil
        radioTrackID = song.id
        radioMessage = radioUsesLocalSongs
            ? "离线电台 · 从本地和已缓存音乐中为你挑选。"
            : "来自你的在线曲库，听完自动为你换一首。"
        queue = PlaybackQueue(ids: [song.id], startingAt: song.id)
        selectedTrackID = song.id
        loadCurrent(autoplay: true)
    }

    private func playOfflineRadio() {
        let local = availableTracks.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        let alternatives = local.filter { $0.id != radioTrackID }
        guard let song = (alternatives.isEmpty ? local : alternatives).randomElement() else {
            isRadioActive = false
            radioMessage = "暂时无法收听电台。请连接服务器，或先导入本地音乐。"
            return
        }
        isRadioActive = true
        radioTrackID = song.id
        radioUsesLocalSongs = true
        radioMessage = (isOnline ? "本地电台" : "离线电台") + " · 从本地和已缓存音乐中为你挑选。"
        queue = PlaybackQueue(ids: [song.id], startingAt: song.id)
        selectedTrackID = song.id
        loadCurrent(autoplay: true)
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.title = "将音乐添加到声屿"
        panel.prompt = "导入音乐"
        panel.message = "可选择多首歌曲或整个文件夹。音乐保留在原位置。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.begin { [weak self] response in
            if response == .OK { Task { @MainActor in self?.importURLs(panel.urls) } }
        }
    }

    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if isImporting { pendingImports.append(contentsOf: urls); return }
        isImporting = true
        importProgress = "正在查找音乐…"
        importTask = Task { [weak self] in
            guard let self else { return }
            let discovered = await Task.detached(priority: .userInitiated) { TrackImporter.discover(urls) }.value
            let existing = Set(tracks.map { TrackImporter.canonicalURL($0.url).path })
            let candidates = discovered.filter { !existing.contains($0.path) }
            var added = 0
            var failed = 0
            for (index, url) in candidates.enumerated() {
                if Task.isCancelled { break }
                importProgress = "正在导入 \(index + 1) / \(candidates.count)"
                do {
                    let track = try await TrackImporter.read(url)
                    guard !Task.isCancelled else { break }
                    tracks.append(track)
                    added += 1
                } catch { failed += 1 }
            }
            isImporting = false
            importProgress = ""
            scheduleSave()
            if failed > 0 {
                showNotice("已导入 \(added) 首；\(failed) 个文件无法读取，请检查文件格式或完整性。", error: true)
            } else if added > 0 {
                showNotice("已添加 \(added) 首音乐，开始你的聆听时光。")
            } else if !discovered.isEmpty {
                showNotice("这些歌曲已在曲库中，无需重复导入。")
            } else {
                showNotice("未找到支持的音频。可导入 MP3、M4A、AAC、WAV、AIFF、CAF 或 FLAC。", error: true)
            }
            if !pendingImports.isEmpty {
                let pending = pendingImports
                pendingImports = []
                importURLs(pending)
            }
        }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL { continuation.resume(returning: url) }
                        else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url { urls.append(url) }
            }
            importURLs(urls)
        }
        return true
    }

    func locateCurrentTrack() {
        guard let track = currentTrack else { return }
        isMiniMode = false
        search = ""
        if isRadioActive { section = .radio; return }
        if !sectionTracks.contains(where: { $0.id == track.id }) { section = .all }
        selectedTrackID = track.id
        // A distinct request also scrolls again when the same song is already selected.
        trackRevealRequest = TrackRevealRequest(trackID: track.id)
    }

    func completeTrackReveal(_ request: TrackRevealRequest) {
        guard trackRevealRequest == request else { return }
        trackRevealRequest = nil
    }

    func showArtists() {
        section = .artists
        search = ""
        selectedTrackID = nil
    }

    func showPlaylists(online: Bool) {
        section = online ? .onlinePlaylists : .playlists
        search = ""
        selectedTrackID = nil
    }

    func showPlaylist(_ id: UUID, online: Bool) {
        let exists = online ? onlinePlaylists.contains { $0.id == id } : playlists.contains { $0.id == id }
        guard exists else { showPlaylists(online: online); return }
        section = online ? .onlinePlaylist(id) : .playlist(id)
        search = ""
        selectedTrackID = nil
    }

    func playlistSummaries(online: Bool) -> [PlaylistSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaries: [PlaylistSummary]
        if online {
            var songs: [UUID: Track] = [:]
            for track in tracks where track.source(on: configuredServer) != nil {
                if let source = track.source(on: configuredServer) { songs[source.id] = track }
            }
            summaries = onlinePlaylists.map { list in
                let contents = list.trackIds.compactMap { songs[$0] }
                return PlaylistSummary(id: list.id, name: list.name, trackCount: list.trackIds.count,
                                       artworkTrack: contents.first { $0.artworkData != nil } ?? contents.first)
            }
        } else {
            summaries = playlists.map { list in
                let contents = list.trackIDs.compactMap { track(for: $0) }
                return PlaylistSummary(id: list.id, name: list.name, trackCount: list.trackIDs.count,
                                       artworkTrack: contents.first { $0.artworkData != nil } ?? contents.first)
            }
        }
        return query.isEmpty ? summaries : summaries.filter { $0.name.localizedStandardContains(query) }
    }

    func showArtist(_ id: String) {
        section = .artist(id)
        search = ""
        selectedTrackID = nil
    }

    func playTrack(_ id: UUID, in source: [UUID]? = nil) {
        guard !isManagingStorage else { return }
        endRadio()
        var ids = source ?? visibleTracks.map(\.id)
        if !ids.contains(id) { ids = [id] }
        if mode == .shuffle { ids = [id] + ids.filter { $0 != id }.shuffled() }
        queue = PlaybackQueue(ids: ids, startingAt: id)
        selectedTrackID = id
        loadCurrent(autoplay: true)
    }

    func playAll(shuffle: Bool = false) {
        guard !isManagingStorage else { return }
        if section == .radio { nextRadioTrack(); return }
        endRadio()
        var ids = visibleTracks.map(\.id)
        guard !ids.isEmpty else { return }
        if shuffle { mode = .shuffle; ids.shuffle() }
        else if mode == .shuffle { mode = .loopAll }
        queue = PlaybackQueue(ids: ids, startingAt: ids.first)
        loadCurrent(autoplay: true)
    }

    func togglePlayback() {
        if isPlaying || isRadioBuffering || loadingTrackID != nil { pause() } else { resume() }
    }

    func resume() {
        guard !isManagingStorage else { return }
        guard !isPlaying else { return }
        if isRadioLoading { return }
        if isRadioActive && currentTrack == nil { nextRadioTrack(); return }
        guard loadingTrackID == nil else { return }
        guard currentTrack != nil else { playAll(); return }
        guard let audioPlayer else { loadCurrent(autoplay: true); return }
        if audioPlayer.currentTime >= audioPlayer.duration - 0.1 {
            audioPlayer.currentTime = 0
            hasCountedCurrentPlayback = false
        }
        playbackDidStart(successfully: audioPlayer.play())
        elapsed = audioPlayer.currentTime
        updateNowPlaying()
        scheduleSave()
    }

    func pause() {
        cancelRadioRequest()
        if isRadioActive { radioMessage = "电台已暂停，随时继续收听。" }
        cancelAudioDownload()
        audioPlayer?.pause()
        isPlaying = false
        elapsed = audioPlayer?.currentTime ?? elapsed
        updateNowPlaying()
        scheduleSave()
    }

    func stop() {
        cancelRadioRequest()
        if isRadioActive { radioMessage = "电台已停止，可以继续收听或换一首。" }
        cancelAudioDownload()
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        hasCountedCurrentPlayback = false
        elapsed = 0
        updateNowPlaying()
        scheduleSave()
    }

    func next(automatic: Bool = false) {
        guard !isManagingStorage else { return }
        if isRadioActive { nextRadioTrack(); return }
        if queue.advance(mode: mode, automatic: automatic) { loadCurrent(autoplay: true) }
        else {
            if automatic { elapsed = playbackDuration }
            audioPlayer?.pause()
            isPlaying = false
            updateNowPlaying()
            scheduleSave()
        }
    }

    func previous() {
        guard !isManagingStorage else { return }
        if isRadioActive { seek(to: 0); return }
        if elapsed > 3 { seek(to: 0); return }
        if queue.retreat(mode: mode) { loadCurrent(autoplay: true) }
        else { seek(to: 0) }
    }

    func selectQueueIndex(_ index: Int) {
        guard !isManagingStorage else { return }
        guard queue.ids.indices.contains(index) else { return }
        queue.select(index)
        loadCurrent(autoplay: true)
    }

    func seek(to time: Double) {
        guard let audioPlayer, time.isFinite else { return }
        audioPlayer.currentTime = min(max(0, time), audioPlayer.duration)
        elapsed = audioPlayer.currentTime
        updateNowPlaying()
        scheduleSave()
    }

    func cycleMode() {
        setPlaybackMode(mode.next)
    }

    func setPlaybackMode(_ newMode: PlaybackMode) {
        guard mode != newMode else { return }
        mode = newMode
        if newMode == .shuffle { queue.shuffleUpcoming() }
        scheduleSave()
    }

    func toggleMute() {
        if volume > 0 { lastAudibleVolume = volume; volume = 0 }
        else { volume = lastAudibleVolume }
    }

    func tick() {
        guard isPlaying, let audioPlayer else { return }
        elapsed = audioPlayer.currentTime
        let second = Int(elapsed)
        if second != lastNowPlayingSecond { lastNowPlayingSecond = second; updateNowPlaying() }
    }

    private func loadCurrent(autoplay: Bool, at position: Double = 0) {
        guard !isManagingStorage else { return }
        cancelAudioDownload()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        hasCountedCurrentPlayback = false
        elapsed = 0
        playbackDuration = 0
        guard let track = currentTrack else { updateNowPlaying(); scheduleSave(); return }
        playbackDuration = track.duration
        if track.remoteSource != nil && !FileManager.default.fileExists(atPath: track.url.path) {
            if autoplay { downloadForPlayback(track, at: position) }
            updateNowPlaying()
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: track.url)
            player.delegate = self
            player.volume = volume
            player.prepareToPlay()
            player.currentTime = min(max(0, position), max(0, player.duration - 0.05))
            audioPlayer = player
            playbackDuration = player.duration
            elapsed = player.currentTime
            if autoplay {
                playbackDidStart(successfully: player.play())
            }
        } catch {
            showNotice("无法打开《\(track.title)》：文件可能已移动、被删除或已损坏。可重新导入文件。", error: true)
        }
        updateNowPlaying()
        scheduleSave()
    }

    // One successful start per loaded playthrough; pausing and seeking retain it.
    func playbackDidStart(successfully started: Bool) {
        isPlaying = started
        guard started else {
            showNotice("无法开始播放，请检查音频输出设备。", error: true)
            return
        }
        if isRadioActive {
            radioMessage = isOnline && currentTrack?.remoteSource != nil
                ? "来自你的在线曲库，听完自动为你换一首。"
                : "离线电台 · 从本地和已缓存音乐中为你挑选。"
        }
        guard !hasCountedCurrentPlayback, let id = queue.currentID,
              let index = position(of: id) else { return }
        tracks[index].playCount += 1
        hasCountedCurrentPlayback = true
        scheduleSave()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            if flag { self.next(automatic: true) }
            else { self.pause(); self.showNotice("音频播放中断，请尝试重新打开文件。", error: true) }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.pause()
            self.showNotice("音频解码失败，文件可能已损坏。", error: true)
        }
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = position(of: id) else { return }
        tracks[index].isFavorite.toggle()
        scheduleSave()
    }

    func enqueueNext(_ id: UUID) {
        guard !isManagingStorage else { return }
        endRadio()
        let hadCurrent = queue.currentID != nil
        queue.insertNext(id)
        if !hadCurrent { loadCurrent(autoplay: false) }
        scheduleSave()
        showNotice("已添加到下一首播放。")
    }

    func removeFromQueue(_ id: UUID) {
        let oldID = queue.currentID
        let wasPlaying = isPlaying
        queue.remove([id])
        if oldID != queue.currentID { loadCurrent(autoplay: wasPlaying) }
        scheduleSave()
    }

    func clearUpcoming() { queue.clearUpcoming(); scheduleSave() }

    private func forgetTrack(_ id: UUID) {
        let source = track(for: id)?.remoteSource
        tracks.removeAll { $0.id == id }
        onlineIDs.remove(id)
        radioUpcomingIDs.removeAll { $0 == id }
        for index in playlists.indices { playlists[index].trackIDs.removeAll { $0 == id } }
        for key in Array(onlinePlaylistCache.keys) {
            onlinePlaylistCache[key] = onlinePlaylistCache[key]?.map { list in
                ServerPlaylist(id: list.id, name: list.name, trackIds: list.trackIds.filter { raw in
                    !(source?.server.absoluteString == key && source?.id == raw)
                })
            }
        }
        queue.remove([id])
        if selectedTrackID == id { selectedTrackID = nil }
        scheduleSave()
    }

    func removeFromLibrary(_ id: UUID) {
        guard !isManagingStorage else { return }
        let wasCurrent = queue.currentID == id
        if wasCurrent { stop(); audioPlayer = nil }
        forgetTrack(id)
        if wasCurrent { loadCurrent(autoplay: false) }
        showNotice("已从曲库移除，原始音乐文件已保留。")
    }

    private func prepareStorageChange(stopping ids: Set<UUID>, cancelConnection: Bool = true) async {
        if cancelConnection {
            connectionAttempt = UUID(); connectionTask?.cancel(); isConnecting = false
        }
        let audioTask = audioDownloadTask, upcoming = upcomingCacheTask, pendingRadio = radioTask
        cancelRadioRequest(); cancelUpcomingCache(); cancelAudioDownload()
        if let current = currentTrack, ids.contains(current.id) {
            audioPlayer?.stop(); audioPlayer = nil; isPlaying = false; elapsed = 0
            playbackDuration = 0; isRadioActive = false; updateNowPlaying()
        }
        await musicClient.cancelDownloads()
        await audioTask?.value; await upcoming?.value; await pendingRadio?.value
    }

    private func cacheFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: musicCacheURL.path) else { return [] }
        guard (try musicCacheURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw OnlineLibraryError.message("缓存目录是符号链接，已保留以避免误删。")
        }
        return try FileManager.default.contentsOfDirectory(at: musicCacheURL, includingPropertiesForKeys: nil)
    }

    private func removeSourceCaches(_ source: RemoteTrackSource) throws {
        let prefix = source.cacheID.uuidString.lowercased() + "-"
        for file in try cacheFiles() where file.lastPathComponent.lowercased().hasPrefix(prefix) { try FileManager.default.removeItem(at: file) }
    }

    private func removeManagedCache(_ song: Track) throws {
        guard song.remoteSource != nil else { return }
        let root = musicCacheURL.standardizedFileURL.resolvingSymlinksInPath()
        guard song.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == root else {
            throw OnlineLibraryError.message("缓存路径不属于声屿，已保留该文件。")
        }
        if FileManager.default.fileExists(atPath: song.url.path) { try FileManager.default.removeItem(at: song.url) }
    }

    func deleteTrack(_ id: UUID, fromCloud: Bool, localFile: Bool) async {
        guard !isManagingStorage, let song = track(for: id) else { return }
        isManagingStorage = true; storageMessage = "正在删除歌曲…"
        defer { isManagingStorage = false; storageMessage = ""; scheduleSave() }
        do {
            let server = try OnlineSettings.serverURL(onlineSettings.server)
            let source = song.source(on: server)
            if fromCloud {
                guard let source else { throw OnlineLibraryError.message("请切换到这首歌曲所属的服务器后删除。") }
                try await musicClient.delete(source, token: connectionToken)
            }
            await prepareStorageChange(stopping: (localFile || song.remoteSource != nil) ? [id] : [])
            if fromCloud {
                if let source { try removeSourceCaches(source) }
                // Remove every reference to this cloud copy, retaining local originals.
                for key in Array(onlinePlaylistCache.keys) where key == server.absoluteString {
                    onlinePlaylistCache[key] = onlinePlaylistCache[key]?.map { ServerPlaylist(id: $0.id, name: $0.name, trackIds: $0.trackIds.filter { $0 != source?.id }) }
                }
                if song.remoteSource != nil { try removeManagedCache(song); forgetTrack(id) }
                else if let index = position(of: id) { tracks[index].cloudSources.removeAll { $0.server == server }; onlineIDs.remove(id) }
            }
            if localFile && song.remoteSource == nil {
                if FileManager.default.fileExists(atPath: song.url.path) { try FileManager.default.trashItem(at: song.url, resultingItemURL: nil) }
                if let index = position(of: id), let remaining = tracks[index].cloudSources.first {
                    tracks[index].remoteSource = remaining
                    tracks[index].cloudSources = []
                    tracks[index].url = musicCacheURL.appendingPathComponent("\(id.uuidString)-\(remaining.sha256).\(song.url.pathExtension.lowercased())")
                } else { forgetTrack(id) }
            }
            ArtworkCache.clear(); invalidateLibraryQueries(); updateNowPlaying()
            showNotice(fromCloud ? "云端歌曲和对应缓存已删除，本地原文件已保留。" : "本地音乐已移到废纸篓。")
        } catch {
            showNotice("删除未完成：" + error.localizedDescription, error: true)
        }
    }

    func clearOnlineCache() async {
        guard !isManagingStorage else { return }
        isManagingStorage = true; storageMessage = "正在清空缓存…"
        defer { isManagingStorage = false; storageMessage = ""; scheduleSave() }
        await prepareStorageChange(stopping: Set(tracks.filter { $0.remoteSource != nil }.map(\.id)))
        do {
            let files = try cacheFiles()
            for file in files { try FileManager.default.removeItem(at: file) }
            for index in tracks.indices where tracks[index].remoteSource != nil { tracks[index].artworkData = nil }
            ArtworkCache.clear(); invalidateLibraryQueries()
            if !isOnline { queue = queue.validated(against: Set(availableTracks.map(\.id))) }
            updateNowPlaying(); showNotice("在线音频和封面缓存已清空，收藏、歌单和本地原文件已保留。")
        } catch { showNotice("部分缓存未能清理：" + error.localizedDescription, error: true) }
    }

    var onlineCacheBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: musicCacheURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func uploadSong(_ id: UUID, server: URL, token: String) async throws -> UUID {
        guard let song = track(for: id) else { throw OnlineLibraryError.message("歌曲已被移除。") }
        if let source = song.source(on: server) { return source.id }
        guard song.remoteSource == nil else { throw OnlineLibraryError.message("《\(song.title)》属于另一台服务器，请切换到该服务器后上传歌单。") }
        guard song.hasLocalCopy else { throw OnlineLibraryError.message("《\(song.title)》尚无本地文件，请先缓存后再上传。") }
        let record = try await musicClient.upload(song, server: server, token: token)
        let remote = try record.track(server: server, cacheRoot: musicCacheURL)
        guard let source = remote.remoteSource, let index = position(of: id) else { throw CancellationError() }
        tracks[index].cloudSources.removeAll { $0.server == server }
        tracks[index].cloudSources.append(source)
        onlineIDs.insert(id)
        // A matching cloud row may already exist; retain the original's identity.
        if remote.id != id, tracks.contains(where: { $0.id == remote.id }) {
            let duplicate = tracks.first { $0.id == remote.id }!
            tracks[index].isFavorite = tracks[index].isFavorite || duplicate.isFavorite
            tracks[index].playCount = max(tracks[index].playCount, duplicate.playCount)
            for i in playlists.indices {
                var seen = Set<UUID>()
                playlists[i].trackIDs = playlists[i].trackIDs.map { $0 == duplicate.id ? id : $0 }.filter { seen.insert($0).inserted }
            }
            if selectedTrackID == duplicate.id { selectedTrackID = id }
            queue.replace(duplicate.id, with: id)
            tracks.removeAll { $0.id == duplicate.id }
        }
        scheduleSave()
        return record.id
    }

    func uploadToCloud(trackID: UUID? = nil, playlistID: UUID? = nil) async {
        guard !isManagingStorage else { return }
        isManagingStorage = true; storageMessage = "正在上传云端…"
        defer { isManagingStorage = false; storageMessage = "" }
        connectionAttempt = UUID(); connectionTask?.cancel(); isConnecting = false
        do {
            let server = try OnlineSettings.serverURL(onlineSettings.server), token = connectionToken
            if let playlistID, let list = playlists.first(where: { $0.id == playlistID }) {
                var ids: [UUID] = []
                for (offset, id) in list.trackIDs.enumerated() {
                    storageMessage = "上传歌单：\(offset + 1) / \(list.trackIDs.count)"
                    ids.append(try await uploadSong(id, server: server, token: token))
                }
                let uploaded = try await musicClient.uploadPlaylist(list, trackIDs: ids, server: server, token: token)
                var lists = onlinePlaylistCache[server.absoluteString] ?? []
                lists.removeAll { $0.id == uploaded.id }; lists.append(uploaded)
                mergeOnlinePlaylists(lists, server: server)
                showNotice("已上传歌单「\(list.name)」，云端按本地歌单顺序播放。")
            } else if let trackID {
                _ = try await uploadSong(trackID, server: server, token: token)
                showNotice("歌曲已上传云端。")
            }
            invalidateLibraryQueries(); scheduleSave()
        } catch { showNotice("上传未完成：" + error.localizedDescription + " 已上传的歌曲会保留，再次上传会继续。", error: true) }
    }

    func savePlaylist(name: String, editing id: UUID?, adding trackID: UUID? = nil) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { return }
        if let id, let index = playlists.firstIndex(where: { $0.id == id }) { playlists[index].name = name }
        else {
            if let trackID, !tracks.contains(where: { $0.id == trackID }) {
                playlistEditor = nil
                showNotice("这首歌曲已从曲库移除，请重新选择。", error: true)
                return
            }
            let list = Playlist(name: name, trackIDs: trackID.map { [$0] } ?? [])
            playlists.append(list)
            if trackID == nil { section = .playlist(list.id) }
            else { showNotice("已创建「\(list.name)」并添加歌曲。") }
        }
        playlistEditor = nil
        scheduleSave()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        if section == .playlist(id) { section = .playlists }
        scheduleSave()
    }

    func addToPlaylist(_ trackID: UUID, playlistID: UUID) {
        guard tracks.contains(where: { $0.id == trackID }) else {
            showNotice("这首歌曲已从曲库移除，无法添加到歌单。", error: true)
            return
        }
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }), !playlists[index].trackIDs.contains(trackID) else { return }
        playlists[index].trackIDs.append(trackID)
        scheduleSave()
        showNotice("已添加到「\(playlists[index].name)」。")
    }

    func removeFromCurrentPlaylist(_ trackID: UUID) {
        guard case .playlist(let id) = section, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].trackIDs.removeAll { $0 == trackID }
        scheduleSave()
    }

    func reveal(_ track: Track) {
        guard FileManager.default.fileExists(atPath: track.url.path) else {
            showNotice("这首在线歌曲还未缓存，播放后可在 Finder 中查看。")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([track.url])
    }

    func showNotice(_ message: String, error: Bool = false) {
        noticeTask?.cancel()
        notice = PlayerNotice(message: message, isError: error)
        if !error {
            noticeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { self?.notice = nil }
            }
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.persistInBackground()
        }
    }

    private func snapshotForSaving() -> LibrarySnapshot {
        let position = isPlaying ? (audioPlayer?.currentTime ?? elapsed) : elapsed
        return LibrarySnapshot(tracks: tracks, playlists: playlists, queue: queue,
                               mode: mode, volume: volume, elapsed: position, onlinePlaylists: onlinePlaylistCache)
    }

    private func persistInBackground() {
        guard persistenceAllowed else { return }
        saveRevision += 1
        let revision = saveRevision
        libraryWriter.save(snapshotForSaving(), to: storageURL) { [weak self] result in
            if case .failure = result {
                Task { @MainActor [weak self] in
                    guard let self, self.saveRevision == revision else { return }
                    self.showNotice("无法保存曲库，请检查磁盘空间和文件权限。", error: true)
                }
            }
        }
    }

    func persistNow() {
        saveTask?.cancel()
        guard persistenceAllowed else { return }
        saveRevision += 1
        do {
            try libraryWriter.flush(snapshotForSaving(), to: storageURL)
        } catch { showNotice("无法保存曲库，请检查磁盘空间和文件权限。", error: true) }
    }

    func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  NSApp.keyWindow != nil, NSApp.keyWindow is NSPanel == false,
                  NSApp.keyWindow?.firstResponder is NSTextView == false,
                  NSApp.keyWindow?.attachedSheet == nil else { return event }
            switch event.keyCode {
            case 49: self.togglePlayback(); return nil
            case 123: self.seek(to: self.elapsed - 5); return nil
            case 124: self.seek(to: self.elapsed + 5); return nil
            default: return event
            }
        }
    }

    private func installSystemControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlayback() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard systemControlsEnabled else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            nowPlayingTrackID = nil
            return
        }
        var info = center.nowPlayingInfo ?? [:]
        if nowPlayingTrackID != track.id {
            info = [
                MPMediaItemPropertyTitle: track.title,
                MPMediaItemPropertyArtist: track.artist,
                MPMediaItemPropertyAlbumTitle: track.album,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
            ]
            if let image = ArtworkCache.image(for: track) {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
            nowPlayingTrackID = track.id
        }
        info[MPMediaItemPropertyPlaybackDuration] = playbackDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
