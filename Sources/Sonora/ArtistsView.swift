import SwiftUI

struct ArtistsView: View {
    @ObservedObject var model: PlayerModel
    @LocalState private var sort = ArtistSort.name

    private var artists: [ArtistSummary] {
        model.sortedVisibleArtists(by: sort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("THE VOICES IN YOUR LIBRARY")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(2.2).foregroundStyle(Theme.accent)
                Text("所有歌手").font(.system(size: 32, weight: .semibold))
                Text(model.sectionSubtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Text("\(model.artists.count) 位歌手 · \(model.tracks.count) 首歌曲 · 播放 \(model.libraryStatistics.playCount) 次")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary.opacity(0.75))
            }
            .padding(.horizontal, 30).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Theme.accent.opacity(0.035), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))

            HStack {
                Text(model.search.isEmpty ? "点击歌手，查看全部歌曲" : "\(artists.count) 位匹配的歌手")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                Menu {
                    Picker("歌手排序", selection: $sort) {
                        ForEach(ArtistSort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label(sort.label, systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }.menuStyle(.borderlessButton).fixedSize().help("歌手排序方式")
            }.padding(.horizontal, 30).padding(.vertical, 12)

            if artists.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: model.search.isEmpty ? "person.2" : "magnifyingglass")
                        .font(.system(size: 31, weight: .light)).foregroundStyle(Theme.secondary)
                    Text(model.search.isEmpty ? "还没有歌手" : "没有找到匹配的歌手")
                        .font(.system(size: 15, weight: .medium))
                    Text(model.search.isEmpty ? "导入音乐后，歌手会自动出现在这里。" : "试试其他歌手名称。")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    if model.search.isEmpty {
                        Button("导入音乐", action: model.openFiles).buttonStyle(AccentButtonStyle(compact: true))
                    } else {
                        Button("清空搜索") { model.search = "" }.buttonStyle(QuietButtonStyle())
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(artists) { artist in
                            Button { model.showArtist(artist.id) } label: {
                                HStack(alignment: .center, spacing: 10) {
                                    if let track = artist.artworkTrack {
                                        ArtworkView(track: track, size: 48, radius: 24)
                                    } else {
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 20)).foregroundStyle(Theme.accent.opacity(0.8))
                                            .frame(width: 48, height: 48).background(Theme.raised, in: Circle())
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(artist.name).font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(Theme.text).lineLimit(1).help(artist.name)
                                        Text("\(artist.tracks.count) 首歌曲").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                        Label("播放 \(artist.playCount) 次", systemImage: "play.circle")
                                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                }
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                                .contentShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(artist.name)，\(artist.tracks.count) 首歌曲，播放 \(artist.playCount) 次")
                            .accessibilityHint("查看这位歌手的歌曲列表")
                        }
                    }.padding(.horizontal, 30).padding(.bottom, 16)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
