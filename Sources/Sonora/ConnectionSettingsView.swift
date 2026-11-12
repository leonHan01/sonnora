import SwiftUI

struct ConnectionSettingsView: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @LocalState private var server: String
    @LocalState private var enabled: Bool
    @LocalState private var token = ""
    @LocalState private var clearToken = false
    @LocalState private var error = ""
    @LocalState private var confirmClearCache = false

    init(model: PlayerModel) {
        self.model = model
        _server = LocalState(initialValue: model.onlineSettings.server)
        _enabled = LocalState(initialValue: model.onlineSettings.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("服务器连接").font(.system(size: 22, weight: .semibold))
            Toggle("启用在线模式", isOn: $enabled)
            VStack(alignment: .leading, spacing: 7) {
                Text("服务器地址").foregroundStyle(Theme.secondary)
                TextField("https://121.40.254.112", text: $server).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("访问令牌").foregroundStyle(Theme.secondary)
                SecureField("留空则使用钥匙串中已保存的令牌", text: $token).textFieldStyle(.roundedBorder)
                    .disabled(clearToken)
                Toggle("清除该服务器已保存的令牌", isOn: $clearToken).font(.system(size: 11))
            }
            Text("连接失败时自动使用本地和已缓存音乐，每 30 秒尝试重新连接。在线歌曲首次播放需要下载，缓存保存在本机。令牌仅保存在系统钥匙串。")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.connectionMessage).font(.system(size: 11)).foregroundStyle(model.isOnline ? Theme.accent : .orange)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("离线缓存").font(.system(size: 13, weight: .medium))
                    Text(ByteCountFormatter.string(fromByteCount: model.onlineCacheBytes, countStyle: .file)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("清空缓存", role: .destructive) { confirmClearCache = true }.disabled(model.isManagingStorage)
            }
            if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Button("打开歌曲管理") {
                    do { NSWorkspace.shared.open(try OnlineSettings.serverURL(server).appendingPathComponent("music.html")) }
                    catch { self.error = error.localizedDescription }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并连接") {
                    do {
                        try model.saveConnectionSettings(server: server, enabled: enabled, token: token, clearToken: clearToken)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.confirmationDialog("清空在线歌曲缓存？", isPresented: $confirmClearCache) {
            Button("清空缓存", role: .destructive) { Task { await model.clearOnlineCache() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会停止正在播放的云端歌曲并清理音频与封面缓存。收藏、歌单、本地原文件和访问令牌会保留。")
        }.padding(26).frame(width: 490).background(Theme.background).foregroundStyle(Theme.text)
    }
}
