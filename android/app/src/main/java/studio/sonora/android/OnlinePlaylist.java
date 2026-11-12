package studio.sonora.android;

import org.json.*;
import java.util.*;

public final class OnlinePlaylist {
    public final String id, name, server;
    public final List<String> trackIds;
    private OnlinePlaylist(String id, String name, String server, List<String> tracks) {
        this.id = id; this.name = name; this.server = server; this.trackIds = Collections.unmodifiableList(tracks);
    }
    public static OnlinePlaylist parse(JSONObject json, String server) throws JSONException {
        String id = UUID.fromString(json.getString("id")).toString(), name = json.getString("name");
        JSONArray values = json.getJSONArray("trackIds");
        if (name.trim().isEmpty() || name.length() > 80 || values.length() > 10000) throw new JSONException("在线歌单信息无效");
        List<String> tracks = new ArrayList<>(); Set<String> unique = new HashSet<>();
        for (int index = 0; index < values.length(); index++) {
            String track = UUID.fromString(values.getString(index)).toString();
            if (!unique.add(track)) throw new JSONException("歌单包含重复歌曲");
            tracks.add(track);
        }
        return new OnlinePlaylist(id, name, server, tracks);
    }
    public OnlinePlaylist without(String trackId) { List<String> ids = new ArrayList<>(trackIds); ids.remove(trackId); return new OnlinePlaylist(id, name, server, ids); }
    public JSONObject json() throws JSONException { return new JSONObject().put("id", id).put("name", name).put("server", server).put("trackIds", new JSONArray(trackIds)); }
}
