import SwiftUI

struct PlaylistAddMenu: View {
    let model: PlayerModel
    let track: Track
    var iconSize: CGFloat = 15

    var body: some View {
        Menu {
            PlaylistDestinationItems(model: model, trackID: track.id)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .help("添加到歌单")
        .accessibilityLabel("将《\(track.title)》添加到歌单")
    }
}

struct PlaylistDestinationItems: View {
    @ObservedObject var model: PlayerModel
    let trackID: UUID

    var body: some View {
        ForEach(model.playlists) { playlist in
            let alreadyAdded = playlist.trackIDs.contains(trackID)
            Button {
                model.addToPlaylist(trackID, playlistID: playlist.id)
            } label: {
                if alreadyAdded {
                    Label("\(playlist.name)（已添加）", systemImage: "checkmark")
                } else {
                    Text(playlist.name)
                }
            }
            .disabled(alreadyAdded)
        }
        if !model.playlists.isEmpty { Divider() }
        Button("新建歌单并添加…", systemImage: "plus") {
            model.playlistEditor = .createAdding(trackID)
        }
    }
}
