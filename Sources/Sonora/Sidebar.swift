import SwiftUI

struct Sidebar: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "waveform").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.background).frame(width: 38, height: 38)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("声屿").font(.system(size: 21, weight: .semibold))
                    Text("S O N O R A").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 23).padding(.top, 12).padding(.bottom, 20)

            Text("音乐资料库").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 25).padding(.bottom, 8)
            VStack(spacing: 5) {
                item("全部音乐", symbol: "square.stack.3d.up", section: .all, count: model.availableTracks.count)
                item("所有歌手", symbol: "person.2", section: .artists, count: model.artists.count)
                item("最近添加", symbol: "clock", section: .recent)
                item("我的收藏", symbol: "heart", section: .favorites, count: model.libraryStatistics.favoriteCount)
                item("我的电台", symbol: "antenna.radiowaves.left.and.right", section: .radio)
            }.padding(.horizontal, 13)

            Text("歌单").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 25).padding(.top, 18).padding(.bottom, 8)
            VStack(spacing: 5) {
                item("在线歌单", symbol: "cloud", section: .onlinePlaylists, count: model.onlinePlaylists.count)
                item("我的歌单", symbol: "music.note.list", section: .playlists, count: model.playlists.count)
            }.padding(.horizontal, 13)

            Spacer(minLength: 15)
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) {
                    Circle().fill(model.isOnline ? Theme.accent : .orange).frame(width: 5, height: 5)
                    Button { model.showConnectionSettings = true } label: {
                        Text(model.isOnline ? "在线模式" : "离线模式").font(.system(size: 11))
                        Image(systemName: "gearshape").font(.system(size: 10))
                    }.buttonStyle(.plain).help(model.connectionMessage)
                    Spacer()
                    if model.isConnecting { ProgressView().controlSize(.mini) }
                    else { IconButton(symbol: "arrow.clockwise", help: "重新连接 / 刷新曲库", size: 11, action: model.reconnect) }
                }
                Button(action: model.openFiles) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("导入本地音乐").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("⌘O").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }.padding(13).background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(model.isImporting)
            }.padding(17).padding(.bottom, 5)
        }
        .frame(width: 210)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func item(_ title: String, symbol: String, section: LibrarySection, count: Int? = nil) -> some View {
        let selected = model.section == section || (section == .artists && model.section.isArtistSection)
            || (section == .onlinePlaylists && model.section.isOnlinePlaylistNavigation)
            || (section == .playlists && model.section.isLocalPlaylistNavigation)
        return Button {
            if section == .radio { model.showRadio() }
            else if section == .artists { model.showArtists() }
            else if section == .onlinePlaylists { model.showPlaylists(online: true) }
            else if section == .playlists { model.showPlaylists(online: false) }
            else {
                model.section = section
                model.selectedTrackID = nil
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 14, weight: selected ? .semibold : .regular)).frame(width: 19)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let count { Text("\(count)").font(.system(size: 10, design: .rounded)).opacity(selected ? 0.8 : 0.5) }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.secondary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(selected ? Theme.accent.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct PlaylistEditorView: View {
    @ObservedObject var model: PlayerModel
    let editor: PlaylistEditor
    @LocalState private var name: String
    @FocusState private var focused: Bool

    private var editingID: UUID? {
        if case .rename(let id) = editor { return id }
        return nil
    }

    private var addingTrackID: UUID? {
        if case .createAdding(let id) = editor { return id }
        return nil
    }

    private var subtitle: String {
        guard let addingTrackID else { return "给这段音乐时光，起个名字。" }
        if let track = model.track(for: addingTrackID) {
            return "将《\(track.title)》添加到新歌单。"
        }
        return "将所选歌曲添加到新歌单。"
    }

    init(model: PlayerModel, editor: PlaylistEditor) {
        self.model = model
        self.editor = editor
        if case .rename(let id) = editor { _name = State(initialValue: model.playlists.first { $0.id == id }?.name ?? "") }
        else { _name = State(initialValue: "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list").font(.system(size: 20)).foregroundStyle(Theme.accent)
                Text(addingTrackID != nil ? "新建歌单并添加" : (editingID == nil ? "创建你的歌单" : "重命名歌单"))
                    .font(.system(size: 20, weight: .semibold))
            }
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
            TextField("例如：夜晚的散步", text: $name).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit(save)
            HStack {
                Spacer()
                Button("取消") { model.playlistEditor = nil }.keyboardShortcut(.cancelAction)
                Button(addingTrackID != nil ? "创建并添加" : (editingID == nil ? "创建歌单" : "保存"), action: save)
                    .buttonStyle(AccentButtonStyle(compact: true))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 360).background(Theme.surface)
        .onAppear { focused = true }
    }

    private func save() { model.savePlaylist(name: name, editing: editingID, adding: addingTrackID) }
}
