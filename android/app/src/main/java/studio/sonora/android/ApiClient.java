package studio.sonora.android;

import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class ApiClient {
    private final Set<HttpURLConnection> inFlight = java.util.concurrent.ConcurrentHashMap.newKeySet();
    public void cancelAll() { for (HttpURLConnection connection : inFlight) connection.disconnect(); inFlight.clear(); }
    private void close(HttpURLConnection connection) { inFlight.remove(connection); connection.disconnect(); }
    public static final class Connection {
        public final String server, token;
        public final int revision;
        public Connection(String server, String token, int revision) { this.server = server; this.token = token; this.revision = revision; }
    }
    public static final class Failure extends IOException {
        public final int status;
        public Failure(String message) { this(0, message); }
        public Failure(int status, String message) { super(message); this.status = status; }
    }
    private HttpURLConnection open(Connection settings, String path, int readTimeout) throws IOException {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
        HttpURLConnection connection = (HttpURLConnection) new URL(settings.server + path).openConnection();
        connection.setInstanceFollowRedirects(false);
        connection.setConnectTimeout(6000); connection.setReadTimeout(readTimeout); connection.setUseCaches(false);
        connection.setRequestProperty("Accept", "application/json, audio/*");
        if (!settings.token.isEmpty()) connection.setRequestProperty("Authorization", "Bearer " + settings.token);
        inFlight.add(connection);
        if (Thread.currentThread().isInterrupted()) { close(connection); throw new InterruptedIOException(); }
        return connection;
    }
    private void check(int status) throws Failure {
        if (status == 401 || status == 403) throw new Failure(status, "认证失败，请在设置中检查访问令牌。");
        if (status != 200) throw new Failure(status, "服务器请求失败（HTTP " + status + "），请稍后重试。");
    }
    private String text(HttpURLConnection connection) throws IOException {
        try (InputStream in = connection.getInputStream(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int read;
            while ((read = in.read(buffer)) != -1) {
                if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
                if (out.size() + read > 8 * 1024 * 1024) throw new Failure("服务器曲库响应过大");
                out.write(buffer, 0, read);
            }
            return out.toString(StandardCharsets.UTF_8.name());
        }
    }
    public List<Song> list(Connection settings) throws IOException, JSONException {
        HttpURLConnection connection = open(settings, "/api/music/tracks", 6000);
        try {
            check(connection.getResponseCode());
            JSONArray array = new JSONArray(text(connection)); List<Song> songs = new ArrayList<>();
            for (int index = 0; index < array.length(); index++) songs.add(Song.remote(array.getJSONObject(index), settings.server));
            return songs;
        } finally { close(connection); }
    }
    public List<OnlinePlaylist> playlists(Connection settings) throws IOException, JSONException {
        HttpURLConnection connection = open(settings, "/api/music/playlists", 6000);
        try {
            check(connection.getResponseCode());
            JSONArray array = new JSONArray(text(connection)); List<OnlinePlaylist> lists = new ArrayList<>(); Set<String> ids = new HashSet<>();
            for (int index = 0; index < array.length(); index++) {
                OnlinePlaylist list = OnlinePlaylist.parse(array.getJSONObject(index), settings.server);
                if (!ids.add(list.id)) throw new JSONException("歌单标识重复");
                lists.add(list);
            }
            return lists;
        } finally { close(connection); }
    }
    public Song radio(Connection settings, String excluded) throws IOException, JSONException {
        String path = "/api/music/tracks/radio";
        if (excluded != null && !excluded.isEmpty()) path += "?exclude=" + UUID.fromString(excluded).toString();
        HttpURLConnection connection = open(settings, path, 6000);
        try {
            int code = connection.getResponseCode();
            if (code == 204) return null;
            if (code == 404 || code == 405) throw new Failure(code, "服务器电台接口未启用（HTTP " + code + "），请更新服务端。");
            check(code);
            return Song.remote(new JSONObject(text(connection)), settings.server);
        } finally { close(connection); }
    }
    public void download(Connection settings, Song song, File file, Core.Progress progress) throws IOException {
        if (!settings.server.equals(song.server)) throw new Failure("歌曲来自其他服务器，请重新选择");
        HttpURLConnection connection = open(settings, "/api/music/tracks/" + UUID.fromString(song.remoteId) + "/audio", 20000);
        try {
            check(connection.getResponseCode());
            long length = connection.getContentLengthLong();
            if (length > Core.MAX_AUDIO || (length >= 0 && length != song.size)) throw new Failure("下载文件大小不符");
            try (InputStream in = connection.getInputStream()) { Core.cache(in, file, song.size, song.sha256, progress); }
        } finally { close(connection); }
    }
    public void delete(Connection settings, Song song) throws IOException {
        String id = song.sourceId(settings.server);
        if (id.isEmpty()) throw new Failure("请切换到歌曲所属服务器后删除");
        HttpURLConnection connection = open(settings, "/api/music/tracks/" + UUID.fromString(id), 15000);
        try {
            connection.setRequestMethod("DELETE"); int code = connection.getResponseCode();
            if (code != 204 && code != 404) check(code);
        } finally { close(connection); }
    }
    private JSONObject write(Connection settings, String path, String method, JSONObject body) throws IOException, JSONException {
        HttpURLConnection connection = open(settings, path, 15000);
        try {
            connection.setRequestMethod(method); connection.setDoOutput(true); connection.setRequestProperty("Content-Type", "application/json");
            byte[] bytes = body.toString().getBytes(StandardCharsets.UTF_8); connection.setFixedLengthStreamingMode(bytes.length);
            try (OutputStream output = connection.getOutputStream()) { output.write(bytes); }
            int code = connection.getResponseCode(); if (code != 201) check(code);
            return new JSONObject(text(connection));
        } finally { close(connection); }
    }
    public OnlinePlaylist uploadPlaylist(Connection settings, String id, String name, List<String> trackIds) throws IOException, JSONException {
        String base = "/api/music/playlists";
        OnlinePlaylist list = OnlinePlaylist.parse(write(settings, base, "POST", new JSONObject().put("id", id).put("name", name)), settings.server);
        for (int offset = 0; offset < trackIds.size(); offset += 1000) {
            list = OnlinePlaylist.parse(write(settings, base + "/" + id + "/tracks", "POST", new JSONObject().put("trackIds", new JSONArray(trackIds.subList(offset, Math.min(offset + 1000, trackIds.size()))))), settings.server);
        }
        List<String> desired = new ArrayList<>(new LinkedHashSet<>(trackIds)); for (String track : list.trackIds) if (!desired.contains(track)) desired.add(track);
        if (!desired.equals(list.trackIds)) list = OnlinePlaylist.parse(write(settings, base + "/" + id + "/order", "PUT", new JSONObject().put("trackIds", new JSONArray(desired)).put("expectedTrackIds", new JSONArray(list.trackIds))), settings.server);
        return list;
    }
    public Song upload(Connection settings, Song song, File file) throws IOException, JSONException {
        long size = file.length(); if (!file.isFile() || size == 0 || size > Core.MAX_AUDIO) throw new Failure("单首歌曲不能为空且不能超过 128 MB");
        String boundary = "Sonora-" + UUID.randomUUID();
        HttpURLConnection connection = open(settings, "/api/music/tracks?reuseExisting=true", 180000);
        try {
            connection.setRequestMethod("POST"); connection.setDoOutput(true); connection.setChunkedStreamingMode(65536);
            connection.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);
            try (OutputStream output = connection.getOutputStream()) {
                String[][] fields = {{"title", song.title}, {"artist", song.artist}, {"album", song.album}, {"duration", Double.toString(song.duration / 1000.0)}};
                for (String[] field : fields) output.write(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + field[0] + "\"\r\n\r\n" + field[1] + "\r\n").getBytes(StandardCharsets.UTF_8));
                output.write(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio." + song.extension + "\"\r\nContent-Type: application/octet-stream\r\n\r\n").getBytes(StandardCharsets.UTF_8));
                try (InputStream input = new FileInputStream(file)) { byte[] buffer = new byte[65536]; int count; while ((count = input.read(buffer)) != -1) { if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException(); output.write(buffer, 0, count); } }
                output.write(("\r\n--" + boundary + "--\r\n").getBytes(StandardCharsets.UTF_8));
            }
            int code = connection.getResponseCode(); if (code != 201) check(code);
            return Song.remote(new JSONObject(text(connection)), settings.server);
        } finally { close(connection); }
    }
    public static boolean requiresOffline(Exception error) {
        if (error instanceof Failure) { int status = ((Failure) error).status; return status == 401 || status == 403; }
        return error instanceof SocketTimeoutException || error instanceof ConnectException || error instanceof UnknownHostException
            || error instanceof NoRouteToHostException || error instanceof SocketException || error instanceof javax.net.ssl.SSLException;
    }
    public static String message(Exception error) {
        return error instanceof Failure ? error.getMessage() : requiresOffline(error) ? "连接不上服务器，已使用本地和缓存音乐。" : "歌曲下载或响应解析失败，请重试或换一首。";
    }
}
