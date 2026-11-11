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
        didSet { queuedTrackCache = nil }
    }
    @Published var mode = PlaybackMode.loopAll
    @Published var isPlaying = false
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
    @Published var showConnectionSettings = false
    @Published private(set) var onlineSettings = OnlineSettings()
    @Published private(set) var isOnline = false
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionMessage = "离线模式 · 本地与已缓存音乐"
    @Published private(set) var loadingTrackID: UUID?

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
        case .artists: "所有歌手"
        case .artist(let id): artists.first { $0.id == id }?.name ?? "歌手"
        case .playlist(let id): playlists.first { $0.id == id }?.name ?? "歌单"
        }
    }
    var sectionSubtitle: String {
        switch section {
        case .all: "让喜欢的旋律，留在此刻。"
        case .recent: "新发现的声音，值得再听一遍。"
        case .favorites: "每一次心动，都有迹可循。"
        case .artists: "从一个名字，听见更多喜欢。"
        case .artist: "这位歌手在你曲库中的全部歌曲。"
        case .playlist: "属于你的音乐片刻。"
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
        case .artists: result = []
        case .artist(let id): result = artists.first { $0.id == id }?.tracks ?? []
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
        let key = TrackQuery(section: section, search: "", sort: sort)
        if let cached = trackQueryCache[key] { return cached }
        var result = sectionTracks
        switch sort {
        case .added:
            if case .playlist = section { break }
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
        let url = try OnlineSettings.serverURL(server)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count <= 1000, !token.contains(where: { $0.isNewline }) else {
            throw OnlineLibraryError.message("访问令牌格式无效。")
        }
        if clearToken || !token.isEmpty { try MusicCredentials.save(clearToken ? "" : token, server: url) }
        let settings = OnlineSettings(enabled: enabled, server: url.absoluteString)
        try FileManager.default.createDirectory(at: connectionSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: connectionSettingsURL, options: .atomic)
        onlineSettings = settings
        connectionToken = MusicCredentials.read(server: url)
        useOfflineMode(message: "离线模式 · 本地与已缓存音乐")
        reconnect()
    }

    func reconnect() {
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
                let incoming = try records.map { try $0.track(server: server, cacheRoot: musicCacheURL) }
                try Task.checkCancellation()
                guard connectionAttempt == attempt else { return }
                mergeOnlineTracks(incoming)
                isOnline = true
                connectionMessage = "在线模式 · \(incoming.count) 首服务器歌曲"
                invalidateLibraryQueries()
            } catch {
                guard !Task.isCancelled, connectionAttempt == attempt else { return }
                useOfflineMode(message: (error as? OnlineLibraryError)?.localizedDescription ?? "连接不上服务器，当前使用离线模式。")
            }
        }
    }

    // Keep local edits and stable IDs across refreshes. Deleted server songs
    // remain available only when a playable local cache already exists.
    func mergeOnlineTracks(_ incoming: [Track]) {
        onlineIDs = Set(incoming.map(\.id))
        var merged = tracks
        var positions = Dictionary(merged.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for var song in incoming {
            if let index = positions[song.id] {
                let existing = merged[index]
                song.isFavorite = existing.isFavorite
                song.playCount = existing.playCount
                song.artworkData = existing.artworkData
                if song.duration == 0 { song.duration = existing.duration }
                if song.artist == "未知艺术家" { song.artist = existing.artist }
                if song.album == "未知专辑" { song.album = existing.album }
                if song != existing { merged[index] = song }
            } else {
                positions[song.id] = merged.count
                merged.append(song)
            }
        }
        if tracks != merged { tracks = merged; scheduleSave() }
    }

    func useOfflineMode(message: String) {
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

    private func cancelAudioDownload() {
        playbackAttempt = UUID()
        audioDownloadTask?.cancel()
        audioDownloadTask = nil
        loadingTrackID = nil
    }

    private func downloadForPlayback(_ track: Track, at position: Double) {
        guard isOnline, onlineIDs.contains(track.id), track.remoteSource?.server.absoluteString == onlineSettings.server else {
            useOfflineMode(message: "连接不上服务器，当前使用离线模式。")
            showNotice("这首歌曲尚未缓存，请选择本地音乐或重新连接服务器。", error: true)
            return
        }
        let attempt = UUID()
        playbackAttempt = attempt
        loadingTrackID = track.id
        let token = connectionToken
        audioDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await musicClient.download(track, token: token)
                try Task.checkCancellation()
                let metadata = try await TrackImporter.read(track.url)
                try Task.checkCancellation()
                guard playbackAttempt == attempt, queue.currentID == track.id else { return }
                if let index = self.position(of: track.id) {
                    tracks[index].duration = metadata.duration
                    tracks[index].artworkData = metadata.artworkData
                    if tracks[index].artist == "未知艺术家" { tracks[index].artist = metadata.artist }
                    if tracks[index].album == "未知专辑" { tracks[index].album = metadata.album }
                }
                loadCurrent(autoplay: true, at: position)
            } catch {
                guard !Task.isCancelled, playbackAttempt == attempt else { return }
                loadingTrackID = nil
                // Do not retain a corrupt/incomplete download as an offline song.
                try? FileManager.default.removeItem(at: track.url)
                useOfflineMode(message: (error as? OnlineLibraryError)?.localizedDescription ?? "歌曲下载失败，当前使用离线模式。")
                showNotice("无法下载《\(track.title)》，已切换到离线模式；本地和已缓存音乐仍可播放。", error: true)
                if currentTrack != nil { loadCurrent(autoplay: true) }
            }
        }
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

    func showArtist(_ id: String) {
        section = .artist(id)
        search = ""
        selectedTrackID = nil
    }

    func playTrack(_ id: UUID, in source: [UUID]? = nil) {
        var ids = source ?? visibleTracks.map(\.id)
        if !ids.contains(id) { ids = [id] }
        if mode == .shuffle { ids = [id] + ids.filter { $0 != id }.shuffled() }
        queue = PlaybackQueue(ids: ids, startingAt: id)
        selectedTrackID = id
        loadCurrent(autoplay: true)
    }

    func playAll(shuffle: Bool = false) {
        var ids = visibleTracks.map(\.id)
        guard !ids.isEmpty else { return }
        if shuffle { mode = .shuffle; ids.shuffle() }
        else if mode == .shuffle { mode = .loopAll }
        queue = PlaybackQueue(ids: ids, startingAt: ids.first)
        loadCurrent(autoplay: true)
    }

    func togglePlayback() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard !isPlaying else { return }
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
        cancelAudioDownload()
        audioPlayer?.pause()
        isPlaying = false
        elapsed = audioPlayer?.currentTime ?? elapsed
        updateNowPlaying()
        scheduleSave()
    }

    func stop() {
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
        if elapsed > 3 { seek(to: 0); return }
        if queue.retreat(mode: mode) { loadCurrent(autoplay: true) }
        else { seek(to: 0) }
    }

    func selectQueueIndex(_ index: Int) {
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

    func removeFromLibrary(_ id: UUID) {
        let oldID = queue.currentID
        let wasPlaying = isPlaying
        tracks.removeAll { $0.id == id }
        for index in playlists.indices { playlists[index].trackIDs.removeAll { $0 == id } }
        queue.remove([id])
        if selectedTrackID == id { selectedTrackID = nil }
        if oldID != queue.currentID { loadCurrent(autoplay: wasPlaying) }
        scheduleSave()
        showNotice("已从曲库移除，原始音乐文件已保留。")
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
        if section == .playlist(id) { section = .all }
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
                               mode: mode, volume: volume, elapsed: position)
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
