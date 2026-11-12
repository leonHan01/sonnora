import SwiftUI

struct PlaylistsView: View {
    @ObservedObject var model: PlayerModel
    let online: Bool

    private var lists: [PlaylistSummary] { model.playlistSummaries(online: online) }
    private var total: Int { online ? model.onlinePlaylists.count : model.playlists.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(online ? "YOUR ONLINE COLLECTIONS" : "MADE FOR YOUR MOMENTS")
                        .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2.2).foregroundStyle(Theme.accent)
                    Text(online ? "在线歌单" : "我的歌单").font(.system(size: 32, weight: .semibold))
                    Text(model.sectionSubtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Text("\(total) 张歌单").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                if online {
                    Button(action: model.openOnlineManagement) { Label("管理在线歌单", systemImage: "arrow.up.right.square") }
                        .buttonStyle(QuietButtonStyle())
                    IconButton(symbol: "arrow.clockwise", help: "刷新在线歌单", action: model.reconnect).disabled(model.isConnecting)
                } else {
                    Button { model.playlistEditor = .create } label: { Label("新建歌单", systemImage: "plus") }
                        .buttonStyle(AccentButtonStyle(compact: true))
                }
            }.padding(.horizontal, 30).padding(.vertical, 16)

            if online && !model.onlinePlaylistMessage.isEmpty {
                Text(model.onlinePlaylistMessage).font(.system(size: 11)).foregroundStyle(.orange)
                    .padding(.horizontal, 30).padding(.bottom, 12)
            }

            if lists.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: model.search.isEmpty ? "music.note.list" : "magnifyingglass")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(Theme.secondary)
                    Text(model.search.isEmpty ? (online ? "还没有在线歌单" : "创建第一张歌单") : "没有找到匹配的歌单")
                        .font(.system(size: 16, weight: .medium))
                    Text(model.search.isEmpty ? (online ? "在服务端管理页创建歌单，添加歌曲后刷新这里。" : "给喜欢的音乐起个名字，放在一起。") : "试试其他歌单名称。")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if !model.search.isEmpty {
                        Button("清空搜索") { model.search = "" }.buttonStyle(QuietButtonStyle())
                    } else if online {
                        Button("打开歌单管理", action: model.openOnlineManagement).buttonStyle(AccentButtonStyle(compact: true))
                    } else {
                        Button("新建歌单") { model.playlistEditor = .create }.buttonStyle(AccentButtonStyle(compact: true))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 14)], spacing: 14) {
                        ForEach(lists) { list in
                            playlistCard(list)
                        }
                    }.padding(.horizontal, 30).padding(.top, 8).padding(.bottom, 20)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func playlistCard(_ list: PlaylistSummary) -> some View {
        Button { model.showPlaylist(list.id, online: online) } label: {
            HStack(spacing: 14) {
                ArtworkView(track: list.artworkTrack, size: 64, radius: 10)
                VStack(alignment: .leading, spacing: 7) {
                    Text(list.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(2).help(list.name)
                    Text("\(list.trackCount) 首歌曲").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Label(online ? "在线歌单" : "本地歌单", systemImage: online ? "cloud" : "music.note.list")
                        .font(.system(size: 10)).foregroundStyle(Theme.accent)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }.padding(15).frame(maxWidth: .infinity, minHeight: 98, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(list.name)，\(list.trackCount) 首歌曲")
            .accessibilityHint("打开歌单详情")
            .contextMenu {
                if online {
                    Button("管理在线歌单", action: model.openOnlineManagement)
                } else {
                    Button("一键上传云端", systemImage: "icloud.and.arrow.up") { Task { await model.uploadToCloud(playlistID: list.id) } }.disabled(model.isManagingStorage)
                    Button("重命名歌单") { model.playlistEditor = .rename(list.id) }
                    Button("删除歌单", role: .destructive) { model.deletePlaylist(list.id) }
                }
            }
    }
}
