package studio.sonora.android;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.*;

public final class Song {
    public String key, remoteId = "", server = "", title = "", artist = "未知艺术家", album = "未知专辑", extension = "mp3", sha256 = "";
    public long size, duration, addedAt = System.currentTimeMillis(), plays;
    public boolean favorite;
    public boolean cached;
    public final Map<String, String> cloudIds = new LinkedHashMap<>();
    public String sourceId(String address) { return server.equals(address) ? remoteId : cloudIds.getOrDefault(address, ""); }
    public boolean hasCloud() { return !server.isEmpty() || !cloudIds.isEmpty(); }
    public boolean local() { return server.isEmpty(); }
    public Song copy() {
        Song song = new Song();
        song.key = key; song.remoteId = remoteId; song.server = server; song.title = title; song.artist = artist; song.album = album;
        song.extension = extension; song.sha256 = sha256; song.size = size; song.duration = duration; song.addedAt = addedAt; song.plays = plays; song.favorite = favorite; song.cached = cached; song.cloudIds.putAll(cloudIds);
        return song;
    }
    public static Song remote(JSONObject json, String server) throws JSONException {
        Song song = new Song();
        song.remoteId = UUID.fromString(json.getString("id")).toString();
        song.server = server;
        song.key = Core.songKey(server, song.remoteId);
        song.title = json.getString("title");
        song.artist = json.optString("artist", "未知艺术家");
        song.album = json.optString("album", "未知专辑");
        song.extension = json.getString("extension");
        song.sha256 = json.getString("sha256");
        song.size = json.getLong("size");
        double duration = json.optDouble("duration", 0);
        if (!Core.EXTENSIONS.contains(song.extension) || !song.sha256.matches("[0-9a-f]{64}") || song.size <= 0 || song.size > Core.MAX_AUDIO || !Double.isFinite(duration) || duration < 0 || duration > 604800) throw new JSONException("歌曲信息无效");
        song.duration = (long)(duration * 1000);
        try { song.addedAt = Instant.parse(json.getString("uploadedAt")).toEpochMilli(); } catch (Exception ignored) { song.addedAt = 0; }
        return song;
    }
    public JSONObject json() throws JSONException {
        return new JSONObject().put("key", key).put("remoteId", remoteId).put("server", server).put("title", title).put("artist", artist)
                .put("album", album).put("extension", extension).put("sha256", sha256).put("size", size).put("duration", duration)
                .put("cloudIds", new JSONObject(cloudIds)).put("addedAt", addedAt).put("plays", plays).put("favorite", favorite);
    }
    public static Song saved(JSONObject json) throws JSONException {
        Song song = new Song();
        song.key = json.getString("key"); song.remoteId = json.optString("remoteId"); song.server = json.optString("server");
        song.title = json.getString("title"); song.artist = json.optString("artist", "未知艺术家"); song.album = json.optString("album", "未知专辑");
        song.extension = json.getString("extension"); song.sha256 = json.getString("sha256"); song.size = json.getLong("size");
        song.duration = Math.max(0, json.optLong("duration")); song.addedAt = json.optLong("addedAt"); song.plays = Math.max(0, json.optLong("plays")); song.favorite = json.optBoolean("favorite");
        if (!song.key.matches("(?:local-)?[0-9a-f]{64}") || !Core.EXTENSIONS.contains(song.extension) || !song.sha256.matches("[0-9a-f]{64}")) throw new JSONException("曲库记录无效");
        JSONObject links = json.optJSONObject("cloudIds");
        if (links != null) { Iterator<String> keys = links.keys(); while (keys.hasNext()) { String server = keys.next(); song.cloudIds.put(Core.server(server), UUID.fromString(links.getString(server)).toString()); } }
        return song;
    }
}
