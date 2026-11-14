import SwiftUI

struct LibraryView: View {
    let model: PlayerModel

    var body: some View {
        GeometryReader { geometry in
            // Layout still follows every pixel, but the page body only needs a
            // different value when the album-column breakpoint is crossed.
            LibraryPage(model: model, showAlbum: geometry.size.width > 820).equatable()
        }
    }
}

struct LibraryPage: View, Equatable {
    @ObservedObject var model: PlayerModel
    let showAlbum: Bool
    @FocusState private var searchFocused: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.showAlbum == rhs.showAlbum
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            if model.section == .radio { RadioView(model: model) }
            else if model.section == .artists { ArtistsView(model: model) }
            else if model.section == .onlinePlaylists || model.section == .playlists {
                PlaylistsView(model: model, online: model.section == .onlinePlaylists)
            }
            else if model.availableTracks.isEmpty && !model.section.isPlaylistDetail { welcome }
            else {
                libraryHero
                trackTable(showAlbum: showAlbum)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSonoraSearch)) { _ in searchFocused = true }
        .onChange(of: model.trackRevealRequest) { _, request in
            if request != nil { searchFocused = false }
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Circle().fill(Theme.accent.opacity(0.8)).frame(width: 5, height: 5)
                Text("YOUR PERSONAL SOUNDSPACE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5)
                    .foregroundStyle(Theme.secondary)
            }.layoutPriority(-1).lineLimit(1)
            Spacer(minLength: 5)
            if model.section != .radio { HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                TextField(model.section == .artists ? "搜索歌手" : ((model.section == .onlinePlaylists || model.section == .playlists) ? "搜索歌单" : "搜索歌曲、艺术家、专辑"), text: $model.search)
                    .textFieldStyle(.plain).font(.system(size: 11)).focused($searchFocused)
                    .accessibilityLabel((model.section == .onlinePlaylists || model.section == .playlists) ? "搜索歌单" : "搜索音乐")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清空搜索")
                } else { Text("⌘F").font(.system(size: 9)).foregroundStyle(Theme.secondary.opacity(0.65)) }
            }.padding(.horizontal, 12).padding(.vertical, 10)
                .frame(width: 225).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8)) }
            IconButton(symbol: "text.line.first.and.arrowtriangle.forward", help: model.showQueue ? "隐藏播放队列" : "显示播放队列", color: model.showQueue ? Theme.accent : Theme.secondary) {
                withAnimation(.easeInOut(duration: 0.18)) { model.showQueue.toggle() }
            }
        }
        .padding(.horizontal, 30).padding(.top, 12).padding(.bottom, 12)
    }

    private var connectionButton: some View {
        Button("连接服务器 / 管理在线歌曲") { model.showConnectionSettings = true }
            .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 12))
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.isOnline ? "在线曲库 · 随处聆听" : "离线聆听 · 自在拥有").font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(Theme.accent)
                    Text("每一首喜欢，\n都有一座岛。").font(.system(size: 37, weight: .semibold)).tracking(1).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    Text("把你的音乐带进来。\n熟悉的旋律，随时为你响起。")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(7)
                    Button(action: model.openFiles) { Label("添加我的音乐", systemImage: "plus") }
                        .buttonStyle(AccentButtonStyle()).padding(.top, 4)
                    connectionButton
                }.frame(maxWidth: .infinity, alignment: .leading)
                AmbientRecord(size: 180).padding(.trailing, 12)
            }.padding(.horizontal, 44)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 25, weight: .light)).foregroundStyle(Theme.accent.opacity(0.8))
                Text("拖入歌曲或文件夹，开启聆听").font(.system(size: 13, weight: .medium))
                Text("MP3  /  M4A  /  AAC  /  WAV  /  AIFF  /  FLAC")
                    .font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(Theme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            .padding(.horizontal, 36).padding(.top, 20)
            HStack(spacing: 28) {
                feature("internaldrive", "本地音乐")
                feature("heart", "珍藏心动")
                feature("music.note.list", "专属歌单")
            }.padding(.top, 16).padding(.bottom, 16)
            Spacer(minLength: 8)
        }
    }

    private func feature(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 10)).foregroundStyle(Theme.secondary)
    }

    private var libraryHero: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                if case .artist = model.section {
                    Button(action: model.showArtists) { Label("所有歌手", systemImage: "chevron.left") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
                if case .onlinePlaylist = model.section {
                    Button { model.showPlaylists(online: true) } label: { Label("在线歌单", systemImage: "chevron.left") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                } else if case .playlist = model.section {
                    Button { model.showPlaylists(online: false) } label: { Label("我的歌单", systemImage: "chevron.left") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
                Text("THE SOUND OF YOUR EVERYDAY").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2.2).foregroundStyle(Theme.accent)
                Text(model.sectionTitle).font(.system(size: 32, weight: .semibold)).lineLimit(1)
                if model.section != .all {
                    Text(model.sectionSubtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                if model.isOnlinePlaylistSection && model.sectionTracks.isEmpty {
                    Text(model.isOnline ? "这张在线歌单还没有可播放的歌曲，请在管理页添加。" : "这张歌单还没有已缓存歌曲，请连接服务器后收听。")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 7) {
                    Text("\(model.sectionTracks.count) 首歌曲")
                    Text("·")
                    Text(durationText(model.sectionStatistics.duration))
                    Text("·")
                    Text("播放 \(model.sectionStatistics.playCount) 次")
                }.font(.system(size: 10)).foregroundStyle(Theme.secondary.opacity(0.75)).padding(.top, 2)
            }
            Spacer(minLength: 0)
            AmbientRecord(size: 104).padding(.trailing, 17)
        }
        .padding(.horizontal, 30).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Theme.accent.opacity(0.035), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func trackTable(showAlbum: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.playAll() } label: { Label("播放全部", systemImage: "play.fill") }
                    .buttonStyle(AccentButtonStyle(compact: true)).disabled(model.visibleTracks.isEmpty)
                IconButton(symbol: "shuffle", help: "随机播放当前列表") { model.playAll(shuffle: true) }
                    .disabled(model.visibleTracks.isEmpty)
                Button(action: model.locateCurrentTrack) { Label("定位当前", systemImage: "scope") }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.currentTrack == nil)
                    .help("定位当前歌曲（⌘J）")
                if model.section == .all {
                    Button { Task { await model.checkInvalidSongs() } } label: {
                        Label(model.isCheckingInvalidSongs ? "检测中…" : "检测无效歌曲", systemImage: "checkmark.shield")
                    }.buttonStyle(QuietButtonStyle()).disabled(model.isCheckingInvalidSongs || model.isManagingStorage)
                }
                if case .playlist(let id) = model.section {
                    Button { Task { await model.uploadToCloud(playlistID: id) } } label: { Label("上传云端", systemImage: "icloud.and.arrow.up") }
                        .buttonStyle(QuietButtonStyle()).disabled(model.isManagingStorage && !model.isUploading)
                }
                Spacer()
                if !model.search.isEmpty {
                    Text("\(model.visibleTracks.count) 个结果").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
                if model.isOnlinePlaylistSection {
                    Label("歌单顺序", systemImage: "list.number").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        .help("按服务端保存的歌单顺序播放")
                } else {
                Menu {
                    Picker("排序", selection: $model.sort) { ForEach(TrackSort.allCases) { Text($0.label).tag($0) } }
                } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.up.arrow.down"); Text(model.sort.label) }.font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }.menuStyle(.borderlessButton).fixedSize().help("排序方式")
                }
            }.padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 12)
            HStack(spacing: 14) {
                Text("#").frame(width: 48, alignment: .center)
                Text("歌曲 / 艺术家").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 94, height: 1)
                if showAlbum { Text("专辑").frame(width: 125, alignment: .leading) }
                Text("播放次数").frame(width: 64, alignment: .trailing)
                Text("时长").frame(width: 44, alignment: .trailing)
                Color.clear.frame(width: 64, height: 1)
            }
            .font(.system(size: 11)).foregroundStyle(Theme.secondary.opacity(0.7))
            .padding(.horizontal, 33).padding(.bottom, 8)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 30)

            if model.visibleTracks.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: model.search.isEmpty ? "music.note.list" : "magnifyingglass").font(.system(size: 31, weight: .light)).foregroundStyle(Theme.secondary)
                    Text(model.search.isEmpty ? "这里还很安静" : "没有找到匹配的音乐").font(.system(size: 15, weight: .medium))
                    Text(emptyHint).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    if !model.search.isEmpty { Button("清空搜索") { model.search = "" }.buttonStyle(QuietButtonStyle()) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TrackList(model: model, showAlbum: showAlbum)
            }
            HStack(spacing: 6) {
                Image(systemName: "headphones").font(.system(size: 9))
                Text("双击歌曲播放").font(.system(size: 9))
                Spacer()
                Text("空格 播放 / 暂停").font(.system(size: 9, design: .monospaced))
            }.foregroundStyle(Theme.secondary.opacity(0.55)).padding(.horizontal, 32).padding(.vertical, 8)
        }
    }

    private var emptyHint: String {
        if !model.search.isEmpty { return "试试歌曲名、艺术家或专辑名称。" }
        if model.isOnlinePlaylistSection { return model.isOnline ? "在服务端管理页面为这张在线歌单添加歌曲。" : "连接服务器后收听；离线时仅显示已缓存的歌曲。" }
        if model.section == .favorites { return "点击歌曲旁的爱心，把喜欢留在这里。" }
        if case .artist = model.section { return "这位歌手的歌曲已移除，可返回所有歌手或导入音乐。" }
        return "在歌曲上点按右键，将它添加到这张歌单。"
    }
}

struct RadioView: View {
    @ObservedObject var model: PlayerModel

    private var playbackLabel: String {
        if model.isRadioBuffering { return "取消加载" }
        if model.isRadioActive && model.isPlaying { return "暂停" }
        if model.isRadioActive && model.currentTrack != nil { return "继续播放" }
        return "开始收听"
    }

    private var sourceLabel: String {
        if !model.isOnline { return "离线电台" }
        return model.radioUsesLocalSongs ? "本地电台" : "在线电台"
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, min(geometry.size.width - 60, 1_200))
            let horizontal = contentWidth >= 620
            let spacious = contentWidth >= 960
            let inset: CGFloat = spacious ? 36 : 24
            let artworkSize = horizontal
                ? min(420, max(230, min(contentWidth * 0.36, geometry.size.height - 250)))
                : min(300, max(0, contentWidth - inset * 2))

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    pageHeader(horizontal: horizontal)
                    VStack(alignment: .leading, spacing: 24) {
                        if horizontal {
                            HStack(alignment: .center, spacing: spacious ? 48 : 28) {
                                artwork(size: artworkSize)
                                songDetails(spacious: spacious)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 28) {
                                artwork(size: artworkSize)
                                    .frame(maxWidth: .infinity)
                                songDetails(spacious: false)
                            }
                        }
                        statusFooter
                    }
                    .padding(inset)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: horizontal ? max(0, min(620, geometry.size.height - 140)) : 0)
                    .background {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(Theme.surface)
                            .overlay {
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.045), .clear],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                            }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.line))
                }
                .frame(maxWidth: 1_200)
                .padding(.horizontal, 30).padding(.top, 20).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func pageHeader(horizontal: Bool) -> some View {
        Group {
            if horizontal {
                HStack(alignment: .bottom, spacing: 24) {
                    heading
                    Spacer(minLength: 0)
                    subtitle.multilineTextAlignment(.trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    heading
                    subtitle
                }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR PERSONAL RADIO").font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(2.2).foregroundStyle(Theme.accent)
            Text("我的电台").font(.system(size: 30, weight: .semibold))
        }
    }

    private var subtitle: some View {
        Text("一首接一首，把下一次心动交给电台。")
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
    }

    private func artwork(size: CGFloat) -> some View {
        ArtworkView(track: model.radioTrack, size: size, radius: 18)
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }

    private func songDetails(spacious: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label(sourceLabel, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.08), in: Capsule())
                Spacer(minLength: 0)
                if let track = model.radioTrack {
                    Button { model.toggleFavorite(track.id) } label: {
                        Label(track.isFavorite ? "已收藏" : "收藏", systemImage: track.isFavorite ? "heart.fill" : "heart")
                    }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 12))
                    PlaylistAddMenu(model: model, track: track)
                }
            }
            .padding(.bottom, spacious ? 24 : 18)

            Text(model.radioTrack?.title ?? "下一首，刚好喜欢")
                .font(.system(size: spacious ? 34 : 26, weight: .semibold))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .help(model.radioTrack?.title ?? "下一首，刚好喜欢")
            if let track = model.radioTrack {
                Text(track.artistName).font(.system(size: spacious ? 18 : 15))
                    .foregroundStyle(Theme.text.opacity(0.8)).lineLimit(2).padding(.top, 12)
                if !track.album.isEmpty {
                    Text(track.album).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .lineLimit(2).padding(.top, 7).help(track.album)
                }
            }

            HStack(spacing: 12) {
                Button {
                    if model.isRadioActive { model.togglePlayback() }
                    else { model.nextRadioTrack() }
                } label: {
                    Label(playbackLabel, systemImage: model.isRadioBuffering ? "xmark" : (model.isRadioActive && model.isPlaying ? "pause.fill" : "play.fill"))
                }.buttonStyle(AccentButtonStyle())
                Button { model.nextRadioTrack() } label: { Label("换一首", systemImage: "forward.end.fill") }
                    .buttonStyle(QuietButtonStyle())
            }.padding(.top, spacious ? 32 : 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusFooter: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.isRadioActive && model.loadingTrackID != nil {
                CurrentDownloadStatus(progress: model.downloadProgress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if model.isRadioLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12))
                        .padding(.top, 1)
                }
                Text(model.radioMessage)
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("电台状态")
            }
            if !model.isOnline {
                Button("服务器连接设置") { model.showConnectionSettings = true }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
        }
        .foregroundStyle(Theme.secondary)
        .padding(.top, 18)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct TrackList: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var selection: TrackSelection
    let showAlbum: Bool

    init(model: PlayerModel, showAlbum: Bool) {
        self.model = model
        self.showAlbum = showAlbum
        selection = model.trackSelection
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                    ForEach(NumberedTracks(tracks: model.visibleTracks)) { row in
                        TrackRow(model: model, track: row.track, number: row.index + 1,
                                 showAlbum: showAlbum, current: model.queue.currentID == row.id,
                                 selected: selection.id == row.id,
                                 playing: model.queue.currentID == row.id && model.isPlaying,
                                 playlistID: playlistID, localCopy: row.track.hasLocalCopy, busy: model.isManagingStorage, uploadBusy: model.isManagingStorage && !model.isUploading)
                            .equatable().id(row.id)
                            .listRowInsets(EdgeInsets(top: 1.5, leading: 22, bottom: 1.5, trailing: 22))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Ordinary selection leaves the user's scroll position alone.
            // Only an explicit locate request scrolls the library.
            .task(id: model.trackRevealRequest) {
                guard let request = model.trackRevealRequest else { return }
                await Task.yield()
                guard !Task.isCancelled, model.trackRevealRequest == request else { return }
                if model.queue.currentID == request.trackID,
                   model.visibleTracks.contains(where: { $0.id == request.trackID }) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(request.trackID, anchor: .center)
                    }
                }
                model.completeTrackReveal(request)
            }
        }
    }

    private var playlistID: UUID? {
        if case .playlist(let id) = model.section { return id }
        return nil
    }
}

struct TrackRow: View, Equatable {
    let model: PlayerModel
    var track: Track
    var number: Int
    var showAlbum: Bool
    var current: Bool
    var selected: Bool
    var playing: Bool
    var playlistID: UUID?
    var localCopy = false
    var busy = false
    var uploadBusy = false
    @LocalState private var hovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.track == rhs.track && lhs.number == rhs.number
            && lhs.showAlbum == rhs.showAlbum && lhs.current == rhs.current
            && lhs.selected == rhs.selected && lhs.playing == rhs.playing
            && lhs.playlistID == rhs.playlistID && lhs.localCopy == rhs.localCopy && lhs.busy == rhs.busy && lhs.uploadBusy == rhs.uploadBusy
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if current {
                    Image(systemName: playing ? "waveform" : "pause.fill").font(.system(size: 15)).foregroundStyle(Theme.accent)
                } else if hovering {
                    Button { play() } label: { Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(Theme.text) }
                        .buttonStyle(.plain).help("播放《\(track.title)》")
                } else { Text(String(format: "%02d", number)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary.opacity(0.6)).lineLimit(1).minimumScaleFactor(0.5) }
            }.frame(width: 48)
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 52, radius: 8)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text(track.title).font(.system(size: 16, weight: .medium)).foregroundStyle(current ? Theme.accent : Theme.text).lineLimit(1).help(track.title)
                        HStack(spacing: 4) {
                            if localCopy { Image(systemName: "internaldrive").help(track.remoteSource == nil ? "本地歌曲" : "已缓存到本地") }
                            if track.hasCloudCopy { Image(systemName: "cloud").foregroundStyle(Theme.accent).help("云端歌曲") }
                        }.font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            .accessibilityLabel(localCopy && track.hasCloudCopy ? "本地与云端都有" : (track.hasCloudCopy ? "云端歌曲" : "本地歌曲"))
                    }
                    Button { model.showArtist(track.artistID) } label: {
                        Text(track.artistName).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }.buttonStyle(.plain).help("查看 \(track.artistName) 的歌曲")
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                if track.remoteSource == nil {
                    IconButton(symbol: "icloud.and.arrow.up", help: "上传云端", size: 13) { Task { await model.uploadToCloud(trackID: track.id) } }.disabled(uploadBusy)
                } else { Color.clear.frame(width: 30, height: 30) }
                IconButton(symbol: track.isFavorite ? "heart.fill" : "heart", help: track.isFavorite ? "取消收藏" : "收藏歌曲", color: track.isFavorite ? Theme.accent : Theme.secondary.opacity(hovering ? 0.9 : 0.35), size: 15) {
                    model.toggleFavorite(track.id)
                }
                PlaylistAddMenu(model: model, track: track)
            }
            .frame(width: 94)
            if showAlbum { Text(track.album).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1).frame(width: 125, alignment: .leading) }
            Text("\(track.playCount)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                .frame(width: 64, alignment: .trailing).help("已播放 \(track.playCount) 次")
            Text(clockText(track.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary).frame(width: 44, alignment: .trailing)
            IconButton(symbol: "trash", help: "删除歌曲", size: 12) { model.deletionTrack = track }.disabled(busy)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(Theme.secondary).frame(width: 24, height: 30)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("歌曲操作")
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(current ? Theme.accent.opacity(0.055) : (selected || hovering ? Color.white.opacity(0.035) : .clear), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent.opacity(0.55) : .clear, lineWidth: 1).allowsHitTesting(false))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: play)
        .onTapGesture { model.selectedTrackID = track.id }
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.title)，\(track.artistName)，\(clockText(track.duration))，播放 \(track.playCount) 次")
    }

    @ViewBuilder private var menuItems: some View {
        Button("播放", systemImage: "play.fill", action: play)
        Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { model.enqueueNext(track.id) }
        Button("查看歌手", systemImage: "person") { model.showArtist(track.artistID) }
        Button(track.isFavorite ? "取消收藏" : "收藏歌曲", systemImage: track.isFavorite ? "heart.slash" : "heart") { model.toggleFavorite(track.id) }
        Menu("添加到歌单") {
            PlaylistDestinationItems(model: model, trackID: track.id)
        }
        if playlistID != nil { Button("从此歌单移除") { model.removeFromCurrentPlaylist(track.id) } }
        Divider()
        Button("在 Finder 中显示", systemImage: "folder") { model.reveal(track) }
            .disabled(track.remoteSource != nil && !FileManager.default.fileExists(atPath: track.url.path))
        if track.remoteSource == nil {
            Button("一键上传云端", systemImage: "icloud.and.arrow.up") { Task { await model.uploadToCloud(trackID: track.id) } }.disabled(uploadBusy)
            Button("从曲库移除（保留文件）") { model.removeFromLibrary(track.id) }.disabled(busy)
        }
        Button("删除歌曲…", systemImage: "trash", role: .destructive) { model.deletionTrack = track }.disabled(busy)
    }

    private func play() { model.playTrack(track.id) }
}

extension Notification.Name {
    static let focusSonoraSearch = Notification.Name("Sonora.FocusSearch")
}
