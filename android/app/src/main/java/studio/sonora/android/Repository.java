package studio.sonora.android;

import android.content.*;
import android.database.Cursor;
import android.graphics.*;
import android.media.MediaMetadataRetriever;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.net.Uri;
import android.os.*;
import android.provider.OpenableColumns;
import android.util.AtomicFile;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;

/** Main-thread catalog mutations, serial atomic persistence, isolated network workers. */
public final class Repository {
    public interface Listener {
        void changed(boolean settingsChanged);
        default void progressChanged() {}
    }
    public static final class Playlist {
        public String id = UUID.randomUUID().toString(), name;
        public final ArrayList<String> keys = new ArrayList<>();
        public Playlist(String name) { this.name = name; }
    }
    public final Context context;
    public final Credentials credentials;
    public final ApiClient api = new ApiClient();
    public final ExecutorService network = Executors.newFixedThreadPool(2);
    public final ExecutorService disk = Executors.newSingleThreadExecutor();
    public final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String, Song> songs = new LinkedHashMap<>();
    private final Set<String> onlineKeys = new HashSet<>();
    public final List<Playlist> playlists = new ArrayList<>();
    private final Map<String, List<OnlinePlaylist>> onlinePlaylistCache = new LinkedHashMap<>();
    public String playlistStatus = "";
    public List<OnlinePlaylist> onlinePlaylists() { return new ArrayList<>(onlinePlaylistCache.getOrDefault(credentials.server(), Collections.emptyList())); }
    public OnlinePlaylist onlinePlaylist(String id) { for (OnlinePlaylist list : onlinePlaylists()) if (list.id.equals(id)) return list; return null; }
    public List<Song> onlinePlaylistSongs(String id) {
        OnlinePlaylist list = onlinePlaylist(id); List<Song> result = new ArrayList<>(); if (list == null) return result;
        Map<String, Song> available = new HashMap<>(); for (Song song : available()) { String sourceId = song.sourceId(list.server); if (!sourceId.isEmpty()) available.put(sourceId, song); }
        for (String track : list.trackIds) { Song song = available.get(track); if (song != null) result.add(song); }
        return result;
    }
    public void mergeOnlinePlaylists(String server, List<OnlinePlaylist> lists) {
        onlinePlaylistCache.put(server, new ArrayList<>(lists)); playlistStatus = ""; save(); emit(false);
    }
    private final List<Listener> listeners = new ArrayList<>();
    private final AtomicFile storage;
    private boolean canSave = true;
    public boolean online, refreshing, storageBusy, uploading, checkingInvalidSongs;
    public int uploadPercent = -1;
    private int uploadGeneration, activeUploads;
    private final ExecutorService uploadWorkers = Executors.newCachedThreadPool();
    private final Map<String, CompletableFuture<String>> songUploads = new HashMap<>();
    public interface StorageCleaner { void drain(Set<String> stopping, boolean allCaches, Runnable completion); }
    public StorageCleaner storageCleaner;
    private void drain(Set<String> stopping, boolean allCaches, Runnable completion) { if (storageCleaner == null) completion.run(); else storageCleaner.drain(stopping, allCaches, completion); }
    private void startStorageChange() {
        storageBusy = true; refreshGeneration++; refreshing = false;
        if (refreshTask != null) refreshTask.cancel(true);
        emit(false);
    }
    public String status = "离线模式 · 本地与缓存音乐", lastKey = "";
    public long lastPosition;
    public final ArrayList<String> lastQueue = new ArrayList<>();
    public Core.Mode mode = Core.Mode.LOOP;
    public int revision;
    public long lastNetworkAttempt;
    public boolean importing;
    private int refreshGeneration;
    private Future<?> refreshTask;
    private List<Song> availableCache, offlineCache;

    public Repository(Context context) {
        this.context = context.getApplicationContext(); credentials = new Credentials(context);
        storage = new AtomicFile(new File(context.getFilesDir(), "library.json"));
        new File(context.getFilesDir(), "audio").mkdirs(); new File(context.getFilesDir(), "artwork").mkdirs();
        load();
    }
    public void observe(Listener listener) { if (!listeners.contains(listener)) listeners.add(listener); }
    public void remove(Listener listener) { listeners.remove(listener); }
    public void emit(boolean settingsChanged) { availableCache = null; offlineCache = null; for (Listener listener : new ArrayList<>(listeners)) listener.changed(settingsChanged); }
    private void emitProgress() { for (Listener listener : new ArrayList<>(listeners)) listener.progressChanged(); }
    public Song song(String key) {
        Song song = songs.get(key);
        if (song == null && key != null) for (Song original : songs.values()) {
            if (!original.local()) continue;
            for (Map.Entry<String, String> link : original.cloudIds.entrySet()) if (Core.songKey(link.getKey(), link.getValue()).equals(key)) return original.copy();
        }
        return song == null ? null : song.copy();
    }
    private void linkOriginal(String key, String server, String id) {
        Song original = songs.get(key); if (original == null) return;
        original.cloudIds.put(server, id);
        List<String> duplicates = new ArrayList<>();
        for (Song song : songs.values()) if (!song.key.equals(key) && song.server.equals(server) && song.remoteId.equals(id)) {
            original.favorite |= song.favorite; original.plays = Math.max(original.plays, song.plays); duplicates.add(song.key);
        }
        for (String duplicate : duplicates) {
            for (Playlist list : playlists) { List<String> mapped = new ArrayList<>(); for (String entry : list.keys) mapped.add(entry.equals(duplicate) ? key : entry); list.keys.clear(); list.keys.addAll(new LinkedHashSet<>(mapped)); }
            for (int i = 0; i < lastQueue.size(); i++) if (lastQueue.get(i).equals(duplicate)) lastQueue.set(i, key);
            if (lastKey.equals(duplicate)) lastKey = key;
            songs.remove(duplicate); onlineKeys.remove(duplicate);
        }
        onlineKeys.add(key); save(); emit(false);
    }
    private void deleteCloudOrphans(String server, String id) throws IOException {
        String prefix = Core.songKey(server, id);
        for (String dir : new String[]{"audio", "artwork"}) {
            File[] files = new File(context.getFilesDir(), dir).listFiles();
            if (files != null) for (File file : files) if (file.getName().startsWith(prefix + "-") || file.getName().equals(prefix + ".jpg")) deleteFile(file);
        }
    }
    public List<Song> all() { List<Song> result = new ArrayList<>(); for (Song song : songs.values()) result.add(song.copy()); return result; }
    public File audio(Song song) { return new File(new File(context.getFilesDir(), "audio"), song.key + "-" + song.sha256 + "." + song.extension); }
    public File artwork(Song song) { return new File(new File(context.getFilesDir(), "artwork"), song.key + ".jpg"); }
    public boolean cached(Song song) { File file = audio(song); return file.isFile() && file.length() == song.size; }
    public List<Song> available() {
        if (availableCache != null) return new ArrayList<>(availableCache);
        List<Song> result = new ArrayList<>();
        for (Song song : songs.values()) {
            boolean cached = cached(song);
            if (cached || (online && credentials.server().equals(song.server) && onlineKeys.contains(song.key))) { Song copy = song.copy(); copy.cached = cached; result.add(copy); }
        }
        result.sort((a, b) -> { int compare = Long.compare(b.addedAt, a.addedAt); return compare != 0 ? compare : a.title.compareToIgnoreCase(b.title); });
        availableCache = result;
        return result;
    }
    public List<Song> offline() { if (offlineCache != null) return new ArrayList<>(offlineCache); List<Song> result = new ArrayList<>(); for (Song song : songs.values()) if (cached(song)) { Song copy = song.copy(); copy.cached = true; result.add(copy); } offlineCache = result; return result; }
    public ApiClient.Connection connection() throws GeneralSecurityException { return new ApiClient.Connection(credentials.server(), credentials.token(credentials.server()), revision); }
    public void saveSettings(String server, boolean enabled, String token, boolean clear) throws GeneralSecurityException {
        if (storageBusy) throw new IllegalStateException("请等待上传或清理完成");
        credentials.save(server, enabled, token, clear); playlistStatus = ""; revision++; refreshGeneration++;
        if (refreshTask != null) refreshTask.cancel(true);
        refreshing = false; markOffline(enabled ? "正在连接服务器…" : "离线模式 · 已关闭在线连接");
        emit(true); refresh();
    }
    public void markOffline(String message) { online = false; status = message; emit(false); }
    public void merge(List<Song> incoming, boolean replace) {
        if (replace) onlineKeys.clear();
        for (Song incomingSong : incoming) {
            Song prior = songs.get(incomingSong.key);
            for (Song candidate : songs.values()) if (candidate.local() && candidate.sourceId(incomingSong.server).equals(incomingSong.remoteId)) { prior = candidate; break; }
            if (prior != null && prior.local()) {
                onlineKeys.add(prior.key); continue;
            }
            if (prior != null) incomingSong.key = prior.key;
            if (prior != null) {
                incomingSong.favorite = prior.favorite; incomingSong.plays = prior.plays;
                if (incomingSong.duration == 0) incomingSong.duration = prior.duration;
                if (incomingSong.artist.equals("未知艺术家")) incomingSong.artist = prior.artist;
                if (incomingSong.album.equals("未知专辑")) incomingSong.album = prior.album;
            }
            songs.put(incomingSong.key, incomingSong); onlineKeys.add(incomingSong.key);
        }
        online = true; save(); emit(false);
    }
    public void refresh() {
        if (refreshing || storageBusy) return;
        if (!credentials.enabled()) { markOffline("离线模式 · 已关闭在线连接"); return; }
        ApiClient.Connection connection;
        try { connection = connection(); } catch (GeneralSecurityException error) { markOffline("请重新输入访问令牌"); return; }
        int generation = ++refreshGeneration; refreshing = true; lastNetworkAttempt = SystemClock.elapsedRealtime(); emit(false);
        refreshTask = network.submit(() -> {
            try {
                List<Song> result = api.list(connection);
                main.post(() -> {
                    if (generation != refreshGeneration || connection.revision != revision) return;
                    status = "在线模式 · " + result.size() + " 首服务器歌曲"; reconcileCatalog(result, connection.server);
                });
                try {
                    List<OnlinePlaylist> lists = api.playlists(connection);
                    main.post(() -> {
                        if (generation != refreshGeneration || connection.revision != revision) return;
                        refreshing = false; mergeOnlinePlaylists(connection.server, lists);
                    });
                } catch (Exception error) {
                    main.post(() -> {
                        if (generation != refreshGeneration || connection.revision != revision) return;
                        refreshing = false; playlistStatus = "在线歌单暂时无法更新，保留上次列表。" + ApiClient.message(error); emit(false);
                    });
                }
            } catch (Exception error) {
                main.post(() -> { if (generation == refreshGeneration && connection.revision == revision) { refreshing = false; markOffline(ApiClient.message(error)); } });
            }
        });
    }
    private void reconcileCatalog(List<Song> incoming, String server) {
        Set<String> present = new HashSet<>(); for (Song song : incoming) present.add(song.remoteId);
        List<Song> removed = new ArrayList<>(); Set<String> stopping = new HashSet<>();
        for (Song song : songs.values()) if (!song.sourceId(server).isEmpty() && !present.contains(song.sourceId(server))) { removed.add(song.copy()); stopping.add(Core.songKey(server, song.sourceId(server))); if (!song.local()) stopping.add(song.key); }
        if (removed.isEmpty()) { merge(incoming, true); return; }
        storageBusy = true;
        drain(stopping, false, () -> {
            try {
                for (Song song : removed) {
                    deleteCloudOrphans(server, song.sourceId(server));
                    if (song.local()) { Song original = songs.get(song.key); if (original != null) original.cloudIds.remove(server); }
                    else { deleteFiles(song); forget(song.key, server, song.remoteId); }
                }
                merge(incoming, true); Ui.covers.evictAll();
            } catch (IOException error) { status = "部分已删除歌曲的缓存清理失败，请重试"; }
            storageBusy = false; save(); emit(false);
        });
    }
    private void deleteFile(File file) throws IOException { if (file.exists() && !file.delete()) throw new IOException("文件清理失败"); }
    private void deleteFiles(Song song) throws IOException { deleteFile(audio(song)); deleteFile(artwork(song)); }
    private void forget(String key, String server, String remoteId) {
        songs.remove(key); onlineKeys.remove(key); for (Playlist list : playlists) list.keys.remove(key);
        lastQueue.remove(key); if (lastKey.equals(key)) { lastKey = ""; lastPosition = 0; }
        List<OnlinePlaylist> lists = onlinePlaylistCache.get(server);
        if (lists != null) lists.replaceAll(list -> list.without(remoteId));
        save();
    }
    private static final class InvalidLocalSong {
        final String key; final File file; final long size, modified; final boolean missing;
        InvalidLocalSong(Song song, File file, boolean missing) { this.key = song.key; this.file = file; this.missing = missing; size = file.length(); modified = file.lastModified(); }
        boolean unchanged() {
            if (missing) return file.getParentFile().isDirectory() && file.getParentFile().canRead() && Files.notExists(file.toPath());
            return file.isFile() && file.canRead() && file.length() == size && file.lastModified() == modified;
        }
    }
    private InvalidLocalSong invalidLocalSong(Song song) {
        File file = audio(song);
        if (!file.exists()) {
            InvalidLocalSong candidate = new InvalidLocalSong(song, file, true);
            return candidate.unchanged() ? candidate : null;
        }
        if (!file.isFile() || !file.canRead()) return null;
        InvalidLocalSong candidate = new InvalidLocalSong(song, file, false);
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            try (InputStream in = new FileInputStream(file)) {
                byte[] buffer = new byte[32768]; int count;
                while ((count = in.read(buffer)) != -1) { if (Thread.currentThread().isInterrupted()) return null; digest.update(buffer, 0, count); }
            }
            if (!candidate.unchanged()) return null;
            if (file.length() != song.size || !Core.hex(digest.digest()).equals(song.sha256)) return candidate;
            MediaExtractor extractor = new MediaExtractor();
            try {
                extractor.setDataSource(file.getAbsolutePath());
                for (int i = 0; i < extractor.getTrackCount(); i++) {
                    String type = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME);
                    if (type != null && type.startsWith("audio/")) return null;
                }
                return candidate.unchanged() ? candidate : null;
            } finally { extractor.release(); }
        } catch (Exception error) { return null; }
    }
    public void checkInvalidSongs() {
        if (checkingInvalidSongs || storageBusy) return;
        checkingInvalidSongs = true; status = "正在检测无效歌曲…"; emitProgress();
        List<Song> snapshot = new ArrayList<>(); for (Song song : songs.values()) if (song.local()) snapshot.add(song.copy());
        network.submit(() -> {
            List<InvalidLocalSong> found = new ArrayList<>();
            for (Song song : snapshot) { if (Thread.currentThread().isInterrupted()) return; InvalidLocalSong candidate = invalidLocalSong(song); if (candidate != null) found.add(candidate); }
            main.post(() -> {
                if (storageBusy) { checkingInvalidSongs = false; status = "当前正在处理歌曲，请稍后重新检测"; emitProgress(); return; }
                Set<String> stopping = new HashSet<>();
                for (InvalidLocalSong candidate : found) { Song song = songs.get(candidate.key); if (song != null && song.local() && audio(song).equals(candidate.file) && candidate.unchanged()) stopping.add(song.key); }
                if (stopping.isEmpty()) { checkingInvalidSongs = false; status = "检测完成：未发现可确认无效的歌曲，无法读取的文件已跳过"; emitProgress(); return; }
                startStorageChange();
                drain(stopping, false, () -> {
                    int removed = 0, linked = 0, failed = 0;
                    for (InvalidLocalSong candidate : found) {
                        Song song = songs.get(candidate.key);
                        if (song == null || !song.local() || !audio(song).equals(candidate.file) || !candidate.unchanged()) continue;
                        try {
                            deleteFiles(song);
                            if (song.hasCloud()) {
                                Song remote = song.copy(); Map.Entry<String, String> link = song.cloudIds.entrySet().iterator().next();
                                remote.server = link.getKey(); remote.remoteId = link.getValue(); remote.cloudIds.remove(link.getKey()); songs.put(song.key, remote); linked++;
                            } else { forget(song.key, song.server, song.remoteId); removed++; }
                        } catch (IOException error) { failed++; }
                    }
                    checkingInvalidSongs = false; storageBusy = false;
                    status = "检测完成：已移除 " + removed + " 首无效歌曲，保留 " + linked + " 首的云端副本" + (failed > 0 ? "，" + failed + " 首清理失败" : "");
                    save(); emit(false);
                });
            });
        });
    }
    public void deleteSong(Song selected, boolean cloud) {
        if (storageBusy) return;
        final ApiClient.Connection connection;
        try { connection = connection(); } catch (Exception error) { status = "请重新设置访问令牌"; emit(false); return; }
        startStorageChange(); status = "正在删除歌曲…"; emit(false);
        network.submit(() -> {
            try {
                if (cloud) api.delete(connection, selected);
                main.post(() -> {
                    String remoteId = selected.sourceId(connection.server);
                    List<Song> affected = new ArrayList<>(); Set<String> stopping = new HashSet<>();
                    for (Song item : songs.values()) if (cloud ? item.sourceId(connection.server).equals(remoteId) : item.key.equals(selected.key)) { affected.add(item.copy()); if (!cloud || !item.local()) stopping.add(item.key); }
                    if (cloud) stopping.add(Core.songKey(connection.server, remoteId));
                    drain(stopping, false, () -> {
                        try {
                            for (Song item : affected) {
                                Song song = songs.get(item.key); if (song == null) continue;
                                if (cloud && song.local()) { song.cloudIds.remove(connection.server); }
                                else {
                                    deleteFiles(song);
                                    if (!cloud && !song.cloudIds.isEmpty()) {
                                        Song remote = song.copy(); Map.Entry<String, String> link = song.cloudIds.entrySet().iterator().next();
                                        remote.server = link.getKey(); remote.remoteId = link.getValue(); remote.cloudIds.clear(); songs.put(song.key, remote);
                                    } else { forget(song.key, song.server, song.remoteId); }
                                }
                            }
                            if (cloud) { deleteCloudOrphans(connection.server, remoteId); List<OnlinePlaylist> lists = onlinePlaylistCache.get(connection.server); if (lists != null) lists.replaceAll(list -> list.without(remoteId)); }
                            Ui.covers.evictAll(); status = cloud ? "云端歌曲和对应缓存已删除，本地原文件已保留" : "应用内本地歌曲副本已删除";
                        } catch (IOException error) { status = "部分文件清理失败，请重试"; }
                        storageBusy = false; save(); emit(false);
                    });
                });
            } catch (Exception error) { main.post(() -> { storageBusy = false; status = "删除未完成：" + ApiClient.message(error); emit(false); }); }
        });
    }
    private CompletableFuture<String> uploadSongShared(ApiClient.Connection connection, Song song, int number, int total, int generation) {
        String remoteId = song.sourceId(connection.server);
        if (!remoteId.isEmpty()) return CompletableFuture.completedFuture(remoteId);
        String key = connection.server + "|" + song.key;
        CompletableFuture<String> existing = songUploads.get(key);
        if (existing != null) return existing;
        CompletableFuture<String> future = CompletableFuture.supplyAsync(() -> {
            try {
                int[] last = {-1}; long[] lastUpdate = {0};
                Song uploaded = api.upload(connection, song, audio(song), sent -> {
                    int percent = (int)Math.min(100, sent * 100 / Math.max(1, song.size));
                    long now = SystemClock.elapsedRealtime();
                    if (percent == last[0] || (percent < 100 && now - lastUpdate[0] < 100)) return;
                    last[0] = percent; lastUpdate[0] = now;
                    main.post(() -> { if (generation == uploadGeneration && uploading) { uploadPercent = percent; status = percent == 100 ? "已发送 " + number + " / " + total + "：" + song.title + "，等待服务器处理…" : "上传 " + number + " / " + total + "：" + song.title + " · " + percent + "%"; emitProgress(); } });
                });
                main.post(() -> linkOriginal(song.key, connection.server, uploaded.remoteId));
                return uploaded.remoteId;
            } catch (Exception error) { throw new CompletionException(error); }
        }, uploadWorkers);
        songUploads.put(key, future);
        future.whenComplete((value, error) -> main.post(() -> songUploads.remove(key, future)));
        return future;
    }
    public void uploadToCloud(String key, String playlistId) {
        if (storageBusy && !uploading) return;
        final ApiClient.Connection connection;
        try { connection = connection(); } catch (Exception error) { status = "请重新设置访问令牌"; emit(false); return; }
        Playlist list = playlistId == null ? null : playlist(playlistId);
        List<Song> selected = new ArrayList<>();
        if (list != null) { for (String id : list.keys) { Song song = song(id); if (song != null) selected.add(song); } }
        else if (song(key) != null) selected.add(song(key));
        if (list == null && selected.isEmpty()) return;
        if (activeUploads++ == 0) startStorageChange();
        uploading = true; status = "正在上传云端…"; uploadPercent = 0; final int generation = ++uploadGeneration; emit(false);
        final String name = list == null ? "" : list.name, id = list == null ? "" : list.id;
        List<CompletableFuture<String>> futures = new ArrayList<>();
        for (int i = 0; i < selected.size(); i++) futures.add(uploadSongShared(connection, selected.get(i), i + 1, selected.size(), generation));
        CompletableFuture.allOf(futures.toArray(new CompletableFuture[0])).thenApplyAsync(ignored -> {
            if (list == null) return null;
            try {
                List<String> ids = new ArrayList<>();
                for (CompletableFuture<String> future : futures) ids.add(future.join());
                return api.uploadPlaylist(connection, id, name, ids);
            } catch (Exception error) { throw new CompletionException(error); }
        }, uploadWorkers).whenComplete((uploaded, error) -> main.post(() -> {
            if (uploaded != null) { List<OnlinePlaylist> values = onlinePlaylists(); values.removeIf(value -> value.id.equals(uploaded.id)); values.add(uploaded); mergeOnlinePlaylists(connection.server, values); }
            activeUploads--;
            if (activeUploads == 0) { uploadGeneration++; uploadPercent = -1; storageBusy = false; uploading = false; }
            Throwable cause = error instanceof CompletionException && error.getCause() != null ? error.getCause() : error;
            status = cause == null ? (uploaded == null ? "歌曲已上传云端" : "歌单已按本地顺序上传云端") : "上传未完成：" + ApiClient.message(cause instanceof Exception ? (Exception) cause : new Exception(cause)) + " 已上传的歌曲会保留，再次上传可继续。";
            save(); emit(false); if (activeUploads == 0) refresh();
        }));
    }
    public void playbackRequestFailed(Exception error) {
        String detail = ApiClient.message(error);
        if (ApiClient.requiresOffline(error)) markOffline(detail);
        else { status = detail; emit(false); }
    }
    public void toggleFavorite(String key) { Song song = songs.get(key); if (song != null) { song.favorite = !song.favorite; save(); emit(false); } }
    public void count(String key) { Song song = songs.get(key); if (song != null) { song.plays++; save(); emit(false); } }
    public void metadata(String key, Metadata metadata) {
        Song song = songs.get(key); if (song == null) return;
        if (metadata.duration > 0) song.duration = metadata.duration;
        if (song.artist.equals("未知艺术家") && !metadata.artist.isEmpty()) song.artist = metadata.artist;
        if (song.album.equals("未知专辑") && !metadata.album.isEmpty()) song.album = metadata.album;
        save(); emit(false);
    }
    public Playlist playlist(String id) { for (Playlist list : playlists) if (list.id.equals(id)) return list; return null; }
    public Playlist createPlaylist(String name) { Playlist list = new Playlist(validName(name)); playlists.add(list); save(); emit(false); return list; }
    public void renamePlaylist(String id, String name) { Playlist list = playlist(id); if (list != null) { list.name = validName(name); save(); emit(false); } }
    public void deletePlaylist(String id) { playlists.removeIf(list -> list.id.equals(id)); save(); emit(false); }
    public void addToPlaylist(String key, String id) {
        Playlist list = playlist(id); if (list == null || !songs.containsKey(key)) return;
        if (!list.keys.contains(key)) { list.keys.add(key); save(); emit(false); }
    }
    public void removeFromPlaylist(String key, String id) { Playlist list = playlist(id); if (list != null) { list.keys.remove(key); save(); emit(false); } }
    private String validName(String input) { String value = input.trim(); if (value.isEmpty() || value.length() > 80) throw new IllegalArgumentException("歌单名应为 1–80 个字符"); return value; }
    public void playback(String key, long position, List<String> queue) {
        lastKey = key == null ? "" : key; lastPosition = Math.max(0, position); lastQueue.clear(); lastQueue.addAll(queue); save();
    }
    public void clearDownloaded() {
        if (storageBusy || importing) { status = "请等待当前上传或导入完成"; emit(false); return; }
        startStorageChange();
        Set<String> stopping = new HashSet<>(); for (Song song : songs.values()) if (!song.local()) stopping.add(song.key);
        drain(stopping, true, () -> {
            try {
                // Include orphaned downloads while preserving every private local import.
                Set<String> keep = new HashSet<>(); for (Song song : songs.values()) if (song.local()) { keep.add(audio(song).getName()); keep.add(artwork(song).getName()); }
                for (String dir : new String[]{"audio", "artwork"}) { File[] files = new File(context.getFilesDir(), dir).listFiles(); if (files != null) for (File file : files) if (!keep.contains(file.getName())) deleteFile(file); }
                Ui.covers.evictAll(); status = "在线音频和封面缓存已清空，本地歌曲、收藏和歌单已保留";
            } catch (IOException error) { status = "部分缓存清理失败，请重试"; }
            storageBusy = false; emit(false);
        });
    }
    public long cachedBytes() { long bytes = 0; for (Song song : songs.values()) if (cached(song) && !song.local()) bytes += song.size; return bytes; }

    public static final class Metadata { public long duration; public String title = "", artist = "", album = ""; }
    public Metadata readMetadata(Song song) {
        Metadata result = new Metadata(); MediaMetadataRetriever retriever = new MediaMetadataRetriever();
        try {
            retriever.setDataSource(audio(song).getAbsolutePath());
            String duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
            result.duration = duration == null ? 0 : Long.parseLong(duration);
            result.title = clean(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE));
            result.artist = clean(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST));
            result.album = clean(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM));
            byte[] cover = retriever.getEmbeddedPicture();
            if (cover != null && cover.length <= 12 * 1024 * 1024) {
                BitmapFactory.Options options = new BitmapFactory.Options(); options.inJustDecodeBounds = true;
                BitmapFactory.decodeByteArray(cover, 0, cover.length, options);
                options.inSampleSize = 1;
                while (Math.max(options.outWidth, options.outHeight) / options.inSampleSize > 600) options.inSampleSize *= 2;
                options.inJustDecodeBounds = false;
                Bitmap bitmap = BitmapFactory.decodeByteArray(cover, 0, cover.length, options);
                if (bitmap != null) {
                    AtomicFile image = new AtomicFile(artwork(song)); FileOutputStream output = image.startWrite();
                    try { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, output); image.finishWrite(output); }
                    catch (Exception error) { image.failWrite(output); }
                    bitmap.recycle();
                }
            }
        } catch (Exception ignored) { /* The platform decoder reports unsupported audio during playback. */ }
        finally { try { retriever.release(); } catch (Exception ignored) {} }
        return result;
    }
    private static String clean(String value) { return value == null ? "" : value.trim(); }
    public void importAudio(List<Uri> uris) {
        if (storageBusy) { status = "请等待上传或清理完成"; emit(false); return; }
        if (importing) { status = "正在导入，请稍候再选择音乐"; emit(false); return; }
        importing = true;
        status = "正在导入本地音乐…"; emit(false);
        network.submit(() -> {
            List<Song> imported = new ArrayList<>(); int failed = 0;
            for (Uri uri : uris) {
                File temporary = null;
                try {
                    String name = "本地音乐";
                    try (Cursor cursor = context.getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                        if (cursor != null && cursor.moveToFirst()) name = cursor.getString(0);
                    }
                    int dot = name.lastIndexOf('.'); String extension = dot < 0 ? "" : name.substring(dot + 1).toLowerCase(Locale.ROOT);
                    if (!Core.EXTENSIONS.contains(extension)) throw new IOException();
                    temporary = File.createTempFile("import-", ".part", new File(context.getFilesDir(), "audio"));
                    MessageDigest hash = MessageDigest.getInstance("SHA-256"); long size = 0;
                    try (InputStream input = context.getContentResolver().openInputStream(uri); FileOutputStream output = new FileOutputStream(temporary)) {
                        if (input == null) throw new IOException();
                        byte[] buffer = new byte[32768]; int count;
                        while ((count = input.read(buffer)) != -1) { size += count; if (size > Core.MAX_AUDIO) throw new IOException(); hash.update(buffer, 0, count); output.write(buffer, 0, count); }
                        output.getFD().sync();
                    }
                    if (size == 0) throw new IOException();
                    Song song = new Song(); song.sha256 = Core.hex(hash.digest()); song.key = "local-" + song.sha256; song.title = name.substring(0, dot); song.size = size; song.extension = extension;
                    boolean existing = audio(song).isFile() && audio(song).length() == size;
                    if (existing) temporary.delete();
                    else Files.move(temporary.toPath(), audio(song).toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                    Metadata metadata = readMetadata(song);
                    if (metadata.duration == 0) { if (!existing) audio(song).delete(); throw new IOException(); }
                    song.duration = metadata.duration;
                    if (!metadata.title.isEmpty()) song.title = metadata.title;
                    if (!metadata.artist.isEmpty()) song.artist = metadata.artist;
                    if (!metadata.album.isEmpty()) song.album = metadata.album;
                    imported.add(song);
                } catch (Exception error) { failed++; }
                finally { if (temporary != null) temporary.delete(); }
            }
            int errors = failed;
            main.post(() -> {
                importing = false;
                int added = 0;
                for (Song song : imported) if (!songs.containsKey(song.key)) { songs.put(song.key, song); added++; }
                status = "已导入 " + added + " 首" + (errors == 0 ? "音乐" : "，" + errors + " 个文件无法读取（单首最多 128 MB）");
                save(); emit(false);
            });
        });
    }
    private void load() {
        if (!storage.getBaseFile().exists() && !new File(storage.getBaseFile() + ".bak").exists()) return;
        try {
            JSONObject root = new JSONObject(new String(storage.readFully(), StandardCharsets.UTF_8));
            if (root.getInt("version") != 1) throw new JSONException("未知曲库版本");
            JSONArray tracks = root.getJSONArray("songs");
            for (int index = 0; index < tracks.length(); index++) { Song song = Song.saved(tracks.getJSONObject(index)); songs.put(song.key, song); }
            JSONArray lists = root.optJSONArray("playlists");
            if (lists != null) for (int i = 0; i < lists.length(); i++) {
                JSONObject value = lists.getJSONObject(i); Playlist list = new Playlist(value.getString("name")); list.id = value.getString("id");
                JSONArray keys = value.getJSONArray("keys");
                for (int j = 0; j < keys.length(); j++) if (songs.containsKey(keys.getString(j)) && !list.keys.contains(keys.getString(j))) list.keys.add(keys.getString(j));
                playlists.add(list);
            }
            JSONArray cloud = root.optJSONArray("onlinePlaylists");
            if (cloud != null) for (int i = 0; i < cloud.length(); i++) {
                JSONObject value = cloud.getJSONObject(i); String server = Core.server(value.getString("server"));
                onlinePlaylistCache.computeIfAbsent(server, ignored -> new ArrayList<>()).add(OnlinePlaylist.parse(value, server));
            }
            lastKey = root.optString("lastKey"); lastPosition = Math.max(0, root.optLong("position"));
            JSONArray queue = root.optJSONArray("queue"); if (queue != null) for (int i = 0; i < queue.length(); i++) if (songs.containsKey(queue.getString(i))) lastQueue.add(queue.getString(i));
            try { mode = Core.Mode.valueOf(root.optString("mode", "LOOP")); } catch (Exception ignored) { mode = Core.Mode.LOOP; }
        } catch (Exception error) {
            try { Files.copy(storage.getBaseFile().toPath(), new File(context.getFilesDir(), "library-recovery-" + System.currentTimeMillis() + ".json").toPath()); }
            catch (Exception backupFailed) { canSave = false; }
            songs.clear(); playlists.clear(); lastQueue.clear(); lastKey = ""; lastPosition = 0;
            status = "曲库读取失败，已保留原数据，请重新连接或导入音乐。";
        }
    }
    public void save() {
        if (!canSave) return;
        try {
            JSONArray tracks = new JSONArray(); for (Song song : songs.values()) tracks.put(song.json());
            JSONArray lists = new JSONArray(); for (Playlist list : playlists) lists.put(new JSONObject().put("id", list.id).put("name", list.name).put("keys", new JSONArray(list.keys)));
            JSONArray cloud = new JSONArray(); for (List<OnlinePlaylist> values : onlinePlaylistCache.values()) for (OnlinePlaylist list : values) cloud.put(list.json());
            byte[] data = new JSONObject().put("onlinePlaylists", cloud).put("version", 1).put("songs", tracks).put("playlists", lists).put("lastKey", lastKey)
                    .put("position", lastPosition).put("queue", new JSONArray(lastQueue)).put("mode", mode.name()).toString().getBytes(StandardCharsets.UTF_8);
            disk.execute(() -> {
                FileOutputStream stream = null;
                try { stream = storage.startWrite(); stream.write(data); storage.finishWrite(stream); }
                catch (Exception error) { if (stream != null) storage.failWrite(stream); main.post(() -> { status = "曲库保存失败，请检查设备存储空间"; emit(false); }); }
            });
        } catch (JSONException error) { status = "曲库保存失败"; emit(false); }
    }
}
