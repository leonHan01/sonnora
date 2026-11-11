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
            else if model.availableTracks.isEmpty { welcome }
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
                TextField(model.section == .artists ? "搜索歌手" : "搜索歌曲、艺术家、专辑", text: $model.search)
                    .textFieldStyle(.plain).font(.system(size: 11)).focused($searchFocused)
                    .accessibilityLabel("搜索音乐")
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
                Text("THE SOUND OF YOUR EVERYDAY").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2.2).foregroundStyle(Theme.accent)
                Text(model.sectionTitle).font(.system(size: 32, weight: .semibold)).lineLimit(1)
                Text(model.sectionSubtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
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
                Spacer()
                if !model.search.isEmpty {
                    Text("\(model.visibleTracks.count) 个结果").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
                Menu {
                    Picker("排序", selection: $model.sort) { ForEach(TrackSort.allCases) { Text($0.label).tag($0) } }
                } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.up.arrow.down"); Text(model.sort.label) }.font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }.menuStyle(.borderlessButton).fixedSize().help("排序方式")
            }.padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 12)
            HStack(spacing: 14) {
                Text("#").frame(width: 26, alignment: .center)
                Text("歌曲 / 艺术家").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 62, height: 1)
                if showAlbum { Text("专辑").frame(width: 125, alignment: .leading) }
                Text("播放次数").frame(width: 64, alignment: .trailing)
                Text("时长").frame(width: 44, alignment: .trailing)
                Color.clear.frame(width: 24, height: 1)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("YOUR PERSONAL RADIO").font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(2.2).foregroundStyle(Theme.accent)
                    Text("我的电台").font(.system(size: 32, weight: .semibold))
                    Text("一首接一首，把下一次心动交给电台。")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                HStack(alignment: .center, spacing: 30) {
                    ArtworkView(track: model.radioTrack, size: 190, radius: 18)
                    VStack(alignment: .leading, spacing: 13) {
                        Label(model.isOnline ? "在线电台" : "离线电台", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text(model.radioTrack?.title ?? "下一首，刚好喜欢")
                            .font(.system(size: 23, weight: .semibold)).lineLimit(3)
                        if let track = model.radioTrack {
                            Text(track.artistName).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                            Text(track.album).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                            HStack(spacing: 10) {
                                Button { model.toggleFavorite(track.id) } label: {
                                    Label(track.isFavorite ? "已收藏" : "收藏", systemImage: track.isFavorite ? "heart.fill" : "heart")
                                }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 12))
                                PlaylistAddMenu(model: model, track: track)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 14) {
                    Button {
                        if model.isRadioActive { model.togglePlayback() }
                        else { model.nextRadioTrack() }
                    } label: {
                        Label(playbackLabel, systemImage: model.isRadioBuffering ? "xmark" : (model.isRadioActive && model.isPlaying ? "pause.fill" : "play.fill"))
                    }.buttonStyle(AccentButtonStyle())
                    Button { model.nextRadioTrack() } label: { Label("换一首", systemImage: "forward.end.fill") }
                        .buttonStyle(QuietButtonStyle())
                    if model.isRadioBuffering { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text(model.isRadioActive && model.loadingTrackID != nil ? "正在缓存歌曲，完成后开始播放…" : model.radioMessage)
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("电台状态")
                if !model.isOnline {
                    Button("服务器连接设置") { model.showConnectionSettings = true }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                }
            }.padding(30).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
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
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(NumberedTracks(tracks: model.visibleTracks)) { row in
                        TrackRow(model: model, track: row.track, number: row.index + 1,
                                 showAlbum: showAlbum, current: model.queue.currentID == row.id,
                                 selected: selection.id == row.id,
                                 playing: model.queue.currentID == row.id && model.isPlaying,
                                 playlistID: playlistID)
                            .equatable().id(row.id)
                    }
                }.padding(.horizontal, 22).padding(.vertical, 6)
            }
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
    @LocalState private var hovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.track == rhs.track && lhs.number == rhs.number
            && lhs.showAlbum == rhs.showAlbum && lhs.current == rhs.current
            && lhs.selected == rhs.selected && lhs.playing == rhs.playing
            && lhs.playlistID == rhs.playlistID
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if current {
                    Image(systemName: playing ? "waveform" : "pause.fill").font(.system(size: 15)).foregroundStyle(Theme.accent)
                } else if hovering {
                    Button { play() } label: { Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(Theme.text) }
                        .buttonStyle(.plain).help("播放《\(track.title)》")
                } else { Text(String(format: "%02d", number)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary.opacity(0.6)) }
            }.frame(width: 26)
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 52, radius: 8)
                VStack(alignment: .leading, spacing: 7) {
                    Text(track.title).font(.system(size: 16, weight: .medium)).foregroundStyle(current ? Theme.accent : Theme.text).lineLimit(1).help(track.title)
                    Button { model.showArtist(track.artistID) } label: {
                        Text(track.artistName).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }.buttonStyle(.plain).help("查看 \(track.artistName) 的歌曲")
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                IconButton(symbol: track.isFavorite ? "heart.fill" : "heart", help: track.isFavorite ? "取消收藏" : "收藏歌曲", color: track.isFavorite ? Theme.accent : Theme.secondary.opacity(hovering ? 0.9 : 0.35), size: 15) {
                    model.toggleFavorite(track.id)
                }
                PlaylistAddMenu(model: model, track: track)
            }
            .frame(width: 62)
            if showAlbum { Text(track.album).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1).frame(width: 125, alignment: .leading) }
            Text("\(track.playCount)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                .frame(width: 64, alignment: .trailing).help("已播放 \(track.playCount) 次")
            Text(clockText(track.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary).frame(width: 44, alignment: .trailing)
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
        Button("从曲库移除（保留文件）", role: .destructive) { model.removeFromLibrary(track.id) }
    }

    private func play() { model.playTrack(track.id) }
}

extension Notification.Name {
    static let focusSonoraSearch = Notification.Name("Sonora.FocusSearch")
}
