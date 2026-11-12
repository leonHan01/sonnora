import SwiftUI

// Only these small views observe download ticks; the library and its menus do
// not need to redraw for every chunk of the current song.
struct CurrentDownloadStatus: View {
    @ObservedObject var progress: PlaybackDownloadProgress

    var body: some View {
        if let active = progress.active {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(active.progress.status)
                    Spacer(minLength: 0)
                    Text("\(active.progress.percentage)%").monospacedDigit()
                    Text(active.progress.byteDescription).foregroundStyle(Theme.secondary).monospacedDigit()
                }.font(.system(size: 11)).lineLimit(1)
                ProgressView(value: active.progress.fraction).progressViewStyle(.linear).tint(Theme.accent)
            }
            .foregroundStyle(Theme.accent)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前歌曲下载进度")
            .accessibilityValue("\(active.progress.status)，\(active.progress.percentage)%，\(active.progress.byteDescription)")
        }
    }
}

struct CurrentDownloadCaption: View {
    @ObservedObject var progress: PlaybackDownloadProgress

    var body: some View {
        if let active = progress.active {
            Text("\(active.progress.status) · \(active.progress.percentage)%")
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.accent).lineLimit(1)
                .help(active.progress.byteDescription)
        }
    }
}

struct PlaybackBar: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 12) {
                Button(action: model.locateCurrentTrack) {
                    HStack(spacing: 12) {
                        ArtworkView(track: model.currentTrack, size: 52, radius: 9)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.currentTrack?.title ?? "音乐，等待响起").font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if model.loadingTrackID != nil {
                                CurrentDownloadCaption(progress: model.downloadProgress)
                            } else {
                                Text(model.currentTrack?.artist ?? "导入一首你喜欢的歌").font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.currentTrack == nil)
                .help("点击定位当前歌曲（⌘J）")
                .accessibilityLabel("定位当前歌曲：\(model.currentTrack?.title ?? "尚未播放")")
                if let track = model.currentTrack {
                    HStack(spacing: 2) {
                        IconButton(symbol: track.isFavorite ? "heart.fill" : "heart", help: track.isFavorite ? "取消收藏当前歌曲" : "收藏当前歌曲", color: track.isFavorite ? Theme.accent : Theme.secondary, size: 13) { model.toggleFavorite(track.id) }
                        PlaylistAddMenu(model: model, track: track, iconSize: 13)
                    }
                }
            }.frame(width: 284)

            VStack(spacing: 7) {
                HStack(spacing: 22) {
                    IconButton(symbol: model.mode.symbol, help: "\(model.mode.label)；点击切换", color: model.mode == .sequential ? Theme.secondary : Theme.accent, size: 13, action: model.cycleMode)
                    IconButton(symbol: "backward.end.fill", help: "上一首（⌘←）", color: Theme.text, size: 16, action: model.previous)
                    Button(action: model.togglePlayback) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .offset(x: model.isPlaying ? 0 : 1)
                            .foregroundStyle(Theme.background).frame(width: 39, height: 39)
                            .background(Theme.accent, in: Circle())
                    }.buttonStyle(.plain).help("播放 / 暂停（空格）")
                        .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                        .disabled(model.availableTracks.isEmpty && !model.isRadioActive)
                    IconButton(symbol: "forward.end.fill", help: "下一首（⌘→）", color: Theme.text, size: 16) { model.next() }
                    IconButton(symbol: "list.bullet", help: "播放队列", color: model.showQueue ? Theme.accent : Theme.secondary, size: 13) {
                        withAnimation(.easeInOut(duration: 0.18)) { model.showQueue.toggle() }
                    }
                }
                PlaybackTimeline(model: model)
            }.frame(maxWidth: 620).frame(maxWidth: .infinity)

            HStack(spacing: 7) {
                VolumeControls(model: model)
                IconButton(symbol: "pip.enter", help: "进入 mini 模式（⌥⌘M）", size: 14) { model.isMiniMode = true }
            }.frame(width: 190)
        }
        .padding(.horizontal, 24).padding(.vertical, 9)
        .frame(height: 84)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Dragging volume only invalidates these controls, not the page or its menus.
struct VolumeControls: View {
    let model: PlayerModel
    @ObservedObject private var volume: PlaybackVolume

    init(model: PlayerModel) {
        self.model = model
        volume = model.playbackVolume
    }

    var body: some View {
        HStack(spacing: 7) {
            IconButton(symbol: volume.value == 0 ? "speaker.slash" : "speaker.wave.2", help: volume.value == 0 ? "取消静音" : "静音", size: 12, action: model.toggleMute)
            Slider(value: Binding(get: { volume.value }, set: { model.volume = $0 }), in: 0...1)
                .controlSize(.mini).tint(Theme.accent).frame(width: 74).accessibilityLabel("音量")
            Text("\(Int(volume.value * 100))").font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.secondary).frame(width: 22)
        }
    }
}

struct MiniPlayerView: View {
    @ObservedObject var model: PlayerModel
    static let windowSize = NSSize(width: 380, height: 124)

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                ArtworkView(track: model.currentTrack, size: 52, radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.currentTrack?.title ?? "音乐，等待响起")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .help(model.currentTrack?.title ?? "尚未播放")
                    if model.loadingTrackID != nil {
                        CurrentDownloadCaption(progress: model.downloadProgress)
                    } else {
                        Text(model.currentTrack?.artist ?? "导入一首你喜欢的歌")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .help(model.currentTrack?.artist ?? "")
                    }
                    if let track = model.currentTrack, !track.album.isEmpty {
                        Text(track.album)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .help(track.album)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 17) {
                IconButton(symbol: "backward.end.fill", help: "上一首（⌘←）", color: Theme.text, size: 15, action: model.previous)
                    .disabled(model.currentTrack == nil)
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 34, height: 34)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .help("播放 / 暂停（空格）")
                .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                .disabled(model.availableTracks.isEmpty && !model.isRadioActive)
                IconButton(symbol: "forward.end.fill", help: "下一首（⌘→）", color: Theme.text, size: 15) { model.next() }
                    .disabled(model.currentTrack == nil)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                HStack(spacing: 4) {
                    IconButton(symbol: "stop.fill", help: "停止并回到开头", color: Theme.text, size: 13, action: model.stop)
                        .disabled(model.currentTrack == nil)
                    playbackModeMenu
                }
            }
            .overlay(alignment: .trailing) {
                IconButton(symbol: "pip.exit", help: "恢复完整窗口（⌥⌘M）", size: 15) { model.isMiniMode = false }
            }
            PlaybackTimeline(model: model)
        }
        .padding(.horizontal, 16)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height, alignment: .top)
    }

    private var playbackModeMenu: some View {
        Menu {
            ForEach(PlaybackMode.allCases, id: \.self) { mode in
                Button { model.setPlaybackMode(mode) } label: {
                    if mode == model.mode { Label(mode.label, systemImage: "checkmark") }
                    else { Text(mode.label) }
                }
            }
        } label: {
            Image(systemName: model.mode.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(model.mode == .sequential ? Theme.secondary : Theme.accent)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("播放顺序：\(model.mode.label)")
        .accessibilityLabel("播放顺序，当前\(model.mode.label)")
        .accessibilityHint("选择播放顺序")
    }
}

/// Only the timeline observes frequent clock updates; its surrounding menus stay stable.
struct PlaybackTimeline: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var progress: PlaybackProgress
    @LocalState private var scrubbing = false
    @LocalState private var previewTime: Double = 0

    init(model: PlayerModel) {
        self.model = model
        self.progress = model.playbackProgress
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(clockText(scrubbing ? previewTime : progress.elapsed)).frame(width: 43, alignment: .trailing)
            Slider(value: Binding(get: { scrubbing ? previewTime : progress.elapsed }, set: { value in
                previewTime = value
                if !scrubbing { model.seek(to: value) }
            }), in: 0...max(1, model.playbackDuration), onEditingChanged: { editing in
                if editing { previewTime = progress.elapsed; scrubbing = true }
                else { scrubbing = false; model.seek(to: previewTime) }
            })
            .controlSize(.mini).tint(Theme.accent).disabled(model.currentTrack == nil)
            .accessibilityLabel("播放进度")
            Text(clockText(model.playbackDuration)).frame(width: 43, alignment: .leading)
        }
        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.secondary)
        .onChange(of: model.queue.currentID) { _, _ in scrubbing = false; previewTime = 0 }
    }
}

struct QueuePanel: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("播放队列").font(.system(size: 15, weight: .semibold))
                Spacer()
                IconButton(symbol: "xmark", help: "关闭队列", size: 11) {
                    withAnimation(.easeInOut(duration: 0.18)) { model.showQueue = false }
                }
            }.padding(.top, 12).padding(.horizontal, 20)
            HStack {
                Text("\(model.queue.ids.count) 首 · \(model.mode.label)").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("清空待播") { model.clearUpcoming() }.buttonStyle(.plain)
                    .font(.system(size: 9)).foregroundStyle(Theme.secondary)
                    .disabled(model.queue.ids.isEmpty)
            }.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 12)
            Rectangle().fill(Theme.line).frame(height: 1)

            if model.queuedTracks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: 27, weight: .light))
                    Text("还没有待播歌曲").font(.system(size: 12))
                    Text("从曲库选一首歌，开始播放。").font(.system(size: 10))
                }.foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(NumberedTracks(tracks: model.queuedTracks)) { row in
                                QueueTrackRow(model: model, track: row.track, index: row.index,
                                              current: row.id == model.queue.currentID,
                                              playing: row.id == model.queue.currentID && model.isPlaying)
                                    .equatable().id(row.id)
                            }
                        }.padding(8)
                    }.onAppear { if let id = model.queue.currentID { proxy.scrollTo(id, anchor: .center) } }
                        .onChange(of: model.queue.currentID) { _, id in
                            if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                        }
                }
            }
            Text("音乐保存在原位置，随时自在聆听。")
                .font(.system(size: 9)).foregroundStyle(Theme.secondary.opacity(0.6))
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 258).background(Theme.sidebar.opacity(0.75))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

}

struct QueueTrackRow: View, Equatable {
    let model: PlayerModel
    let track: Track
    let index: Int
    let current: Bool
    let playing: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.track == rhs.track && lhs.index == rhs.index
            && lhs.current == rhs.current && lhs.playing == rhs.playing
    }

    var body: some View {
        Button { model.selectQueueIndex(index) } label: {
            HStack(spacing: 10) {
                ArtworkView(track: track, size: 46, radius: 7)
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title).font(.system(size: 14, weight: .medium)).foregroundStyle(current ? Theme.accent : Theme.text).lineLimit(1).help(track.title)
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if current { Image(systemName: playing ? "waveform" : "pause.fill").font(.system(size: 14)).foregroundStyle(Theme.accent) }
                else { Text(clockText(track.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary) }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(current ? Theme.accent.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).contextMenu {
            Button("从队列移除") { model.removeFromQueue(track.id) }
        }
    }
}
