import SwiftUI
import Combine
import UniformTypeIdentifiers

@main
struct SonoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: PlayerModel

    init() {
        let override = ProcessInfo.processInfo.environment["SONORA_LIBRARY_PATH"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SonoraLibraryPath") as? String
        let url = override.map { URL(fileURLWithPath: $0) } ?? LibraryPersistence.defaultURL
        _model = StateObject(wrappedValue: PlayerModel(storageURL: url))
    }

    var body: some Scene {
        Window("声屿 · Sonora", id: "main") {
            RootView(model: model)
                .onAppear {
                    delegate.model = model
                    model.installKeyboardMonitor()
                }
        }
        .sonoraWindowConfiguration()
        .commands {
            CommandGroup(after: .appSettings) {
                Button("服务器连接…") { model.showConnectionSettings = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("导入音乐…", action: model.openFiles).keyboardShortcut("o", modifiers: .command)
                Button("新建歌单…") {
                    model.isMiniMode = false
                    model.playlistEditor = .create
                }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("搜索音乐") {
                    model.isMiniMode = false
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .focusSonoraSearch, object: nil)
                    }
                }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("播放") {
                Button(model.isPlaying ? "暂停" : "播放", action: model.togglePlayback).keyboardShortcut("p", modifiers: .command)
                Button("停止", action: model.stop).disabled(model.currentTrack == nil)
                Button("上一首", action: model.previous).keyboardShortcut(.leftArrow, modifiers: .command)
                Button("下一首") { model.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("定位当前歌曲", action: model.locateCurrentTrack)
                    .keyboardShortcut("j", modifiers: .command)
                    .disabled(model.currentTrack == nil)
                Divider()
                Button("切换播放模式（\(model.mode.label)）", action: model.cycleMode).keyboardShortcut("r", modifiers: .command)
                Button("静音 / 取消静音", action: model.toggleMute).keyboardShortcut("m", modifiers: [.command, .shift])
                Button("显示 / 隐藏播放队列") { model.showQueue.toggle() }.keyboardShortcut("l", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(model.isMiniMode ? "退出 mini 模式" : "进入 mini 模式") { model.isMiniMode.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于声屿") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "声屿 · Sonora",
                        .applicationVersion: "1.6.0",
                        .version: "27",
                        .credits: NSAttributedString(string: "每一首喜欢，都有一座岛。\n原生 macOS 在线与离线音乐播放器")
                    ])
                }
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: PlayerModel
    @LocalState private var dropTargeted = false
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if model.isMiniMode {
                MiniPlayerView(model: model)
            } else {
                fullPlayer
            }
        }
        .background(PlayerWindowPresentation(isMiniMode: model.isMiniMode, fullMinimumWidth: model.showQueue ? 1190 : 980))
        .background(Theme.background).foregroundStyle(Theme.text).tint(Theme.accent)
        .preferredColorScheme(.dark)
        .onReceive(timer) { _ in model.tick() }
        .task { model.startOnlineMode() }
        .sheet(item: $model.playlistEditor) { editor in PlaylistEditorView(model: model, editor: editor) }
        .sheet(isPresented: $model.showConnectionSettings) { ConnectionSettingsView(model: model) }
        .confirmationDialog("删除歌曲", isPresented: Binding(get: { model.deletionTrack != nil }, set: { if !$0 { model.deletionTrack = nil } }), presenting: model.deletionTrack) { track in
            if track.remoteSource == nil {
                Button("将本地文件移到废纸篓", role: .destructive) { Task { await model.deleteTrack(track.id, fromCloud: false, localFile: true) } }
                Button("仅从本地曲库移除（保留文件）") { model.removeFromLibrary(track.id) }
            }
            if track.hasCloudCopy {
                Button("删除云端歌曲及本机缓存", role: .destructive) { Task { await model.deleteTrack(track.id, fromCloud: true, localFile: false) } }
            }
            Button("取消", role: .cancel) {}
        } message: { track in
            Text("《\(track.title)》：删除云端副本会影响所有在线歌单，其他设备重新连接后同步清理缓存。本地原文件可移到废纸篓恢复。")
        }
    }

    private var fullPlayer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Sidebar(model: model)
                VStack(spacing: 0) {
                    LibraryView(model: model)
                    if let id = model.loadingTrackID, let track = model.track(for: id) {
                        HStack(spacing: 9) {
                            Image(systemName: "arrow.down.circle").font(.system(size: 19, weight: .light))
                            VStack(alignment: .leading, spacing: 7) {
                                Text("正在缓存《\(track.title)》").font(.system(size: 11)).lineLimit(1).help(track.title)
                                CurrentDownloadStatus(progress: model.downloadProgress)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("取消", action: model.pause).buttonStyle(.plain)
                        }.foregroundStyle(Theme.accent).padding(.horizontal, 22).padding(.vertical, 10).background(Theme.surface)
                    }
                    if model.isManagingStorage {
                        HStack { ProgressView().controlSize(.small); Text(model.storageMessage).font(.system(size: 11)); Spacer() }
                            .padding(12).foregroundStyle(Theme.accent).background(Theme.surface)
                    }
                    if model.isImporting {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text(model.importProgress).font(.system(size: 11))
                            Spacer()
                        }.foregroundStyle(Theme.accent).padding(.horizontal, 30).padding(.vertical, 12).background(Theme.surface)
                    }
                    if let notice = model.notice {
                        HStack(spacing: 9) {
                            Image(systemName: notice.isError ? "exclamationmark.circle" : "checkmark.circle")
                                .foregroundStyle(notice.isError ? .orange : Theme.accent)
                            Text(notice.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            IconButton(symbol: "xmark", help: "关闭提示", size: 10) { model.notice = nil }
                        }.padding(.leading, 22).padding(.trailing, 12).padding(.vertical, 7).background(Theme.raised)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showQueue { QueuePanel(model: model).transition(.move(edge: .trailing).combined(with: .opacity)) }
            }
            PlaybackBar(model: model)
        }
        .frame(minWidth: model.showQueue ? 1190 : 980, minHeight: 700)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.accent, lineWidth: 2).padding(5)
                    .background(Theme.accent.opacity(0.04)).allowsHitTesting(false)
                VStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 37))
                    Text("松开鼠标，导入音乐").font(.system(size: 17, weight: .semibold))
                }.foregroundStyle(Theme.accent).padding(35).background(Theme.background.opacity(0.96), in: RoundedRectangle(cornerRadius: 18)).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: model.acceptDrop)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: PlayerModel? {
        didSet {
            if !pendingURLs.isEmpty { model?.importURLs(pendingURLs); pendingURLs = [] }
        }
    }
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.importURLs(urls) } else { pendingURLs.append(contentsOf: urls) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.persistNow() }
}
