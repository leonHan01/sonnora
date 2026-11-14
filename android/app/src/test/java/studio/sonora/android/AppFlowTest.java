package studio.sonora.android;

import android.content.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.*;
import org.robolectric.android.controller.*;
import org.robolectric.annotation.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35, application = SonoraApp.class)
@LooperMode(LooperMode.Mode.PAUSED)
@GraphicsMode(GraphicsMode.Mode.LEGACY)
public class AppFlowTest {
    private Repository repo;
    @Before public void prepareOfflineApp() throws Exception {
        repo = SonoraApp.repository(RuntimeEnvironment.getApplication());
        repo.credentials.save("https://example.invalid", false, "", false);
    }
    @After public void finish() throws Exception {
        repo.disk.submit(() -> {}).get(5, TimeUnit.SECONDS);
        repo.network.shutdownNow(); repo.disk.shutdown();
        Shadows.shadowOf(Looper.getMainLooper()).idle();
    }
    private Song fixture() throws Exception {
        Song song = new Song(); song.server = "https://example.invalid"; song.remoteId = UUID.randomUUID().toString(); song.key = Core.songKey(song.server, song.remoteId);
        song.title = "Test song"; song.artist = "Test artist"; song.album = "Test album"; song.sha256 = Core.hash("fixture".getBytes(StandardCharsets.UTF_8)); song.size = 7; song.duration = 12000;
        repo.merge(Collections.singletonList(song), false);
        try (FileOutputStream output = new FileOutputStream(repo.audio(song))) { output.write("fixture".getBytes(StandardCharsets.UTF_8)); }
        repo.markOffline("Offline test"); return song;
    }
    private TextView text(View view, String value) {
        if (view instanceof TextView && value.contentEquals(((TextView)view).getText())) return (TextView)view;
        if (view instanceof ViewGroup) for (int i = 0; i < ((ViewGroup)view).getChildCount(); i++) { TextView found = text(((ViewGroup)view).getChildAt(i), value); if (found != null) return found; }
        return null;
    }
    @Test public void navigationBuildsRadioPlaylistsAndSettingsWithoutADevice() {
        ServiceController<PlaybackService> playback = Robolectric.buildService(PlaybackService.class).create();
        Shadows.shadowOf(RuntimeEnvironment.getApplication()).setComponentNameAndServiceForBindService(
                new ComponentName(repo.context, PlaybackService.class), playback.get().onBind(new Intent(repo.context, PlaybackService.class)));
        ActivityController<MainActivity> controller = Robolectric.buildActivity(MainActivity.class).setup();
        MainActivity activity = controller.get(); View root = activity.getWindow().getDecorView();
        assertNotNull(text(root, "音乐，随时在身边。"));
        ((View)text(root, "电台").getParent()).performClick(); assertNotNull(text(root, "我的电台"));
        Intent started; boolean requestedRadio = false;
        while ((started = Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedService()) != null) if (PlaybackService.RADIO.equals(started.getAction())) requestedRadio = true;
        assertTrue("Selecting radio requests playback", requestedRadio);
        ((View)text(root, "歌单").getParent()).performClick(); assertNotNull(text(root, "我的歌单"));
        ((View)text(root, "设置").getParent()).performClick(); assertNotNull(text(root, "连接你的音乐")); assertNotNull(text(root, "保存并连接"));
        controller.pause().stop().destroy();
        playback.destroy();
    }
    @Test public void favoritesPlaylistsAndPlayCountsSurviveCatalogRefreshAndRelaunch() throws Exception {
        Song song = fixture(); repo.toggleFavorite(song.key); repo.count(song.key);
        Repository.Playlist list = repo.createPlaylist("夜间"); repo.addToPlaylist(song.key, list.id); repo.addToPlaylist(song.key, list.id);
        Song refreshed = song.copy(); refreshed.title = "Updated title"; refreshed.favorite = false; refreshed.plays = 0;
        repo.merge(Collections.singletonList(refreshed), true); repo.markOffline("Offline");
        repo.disk.submit(() -> {}).get(5, TimeUnit.SECONDS);
        Repository restored = new Repository(RuntimeEnvironment.getApplication());
        try {
            assertTrue(restored.song(song.key).favorite); assertEquals(1, restored.song(song.key).plays);
            assertEquals(Collections.singletonList(song.key), restored.playlist(list.id).keys);
            assertEquals(1, restored.available().size()); assertEquals("Updated title", restored.available().get(0).title);
        } finally { restored.network.shutdownNow(); restored.disk.shutdownNow(); }
    }
    @Test public void uncachedSongsDisappearOfflineWithoutLosingFavoritesOrPlaylistMembership() throws Exception {
        Song song = fixture(); repo.toggleFavorite(song.key); Repository.Playlist list = repo.createPlaylist("Favorites"); repo.addToPlaylist(song.key, list.id);
        assertTrue(repo.audio(song).delete()); repo.markOffline("No server");
        assertTrue(repo.available().isEmpty()); assertTrue(repo.song(song.key).favorite); assertTrue(repo.playlist(list.id).keys.contains(song.key));
        repo.merge(Collections.singletonList(song), true); assertEquals(1, repo.available().size());
    }
    private void awaitInvalidScan() throws Exception {
        for (int i = 0; i < 500 && repo.checkingInvalidSongs; i++) { Thread.sleep(10); Shadows.shadowOf(Looper.getMainLooper()).idle(); }
        assertFalse("Invalid song scan completes", repo.checkingInvalidSongs);
    }
    @Test public void invalidLocalSongsAreRemovedWithoutTouchingCloudSongsOrPlaylists() throws Exception {
        Song remote = fixture();
        Song missing = remote.copy(); missing.key = "local-" + missing.sha256; missing.server = ""; missing.remoteId = "";
        repo.merge(Collections.singletonList(missing), false);
        Repository.Playlist list = repo.createPlaylist("Keep cloud"); repo.addToPlaylist(missing.key, list.id); repo.addToPlaylist(remote.key, list.id);
        repo.playback(missing.key, 0, Arrays.asList(missing.key, remote.key));
        repo.checkInvalidSongs(); awaitInvalidScan();
        assertNull(repo.song(missing.key)); assertNotNull(repo.song(remote.key));
        assertEquals(Collections.singletonList(remote.key), list.keys); assertEquals(Collections.singletonList(remote.key), repo.lastQueue);
        repo.disk.submit(() -> {}).get(5, TimeUnit.SECONDS);
        Repository restored = new Repository(repo.context);
        try { assertNull(restored.song(missing.key)); assertNotNull(restored.song(remote.key)); } finally { restored.network.shutdownNow(); restored.disk.shutdownNow(); }
    }
    @Test public void corruptLocalCopyKeepsCloudLinkFavoriteAndPlaylist() throws Exception {
        Song remote = fixture();
        Song local = remote.copy(); local.key = "local-" + local.sha256; local.server = ""; local.remoteId = "";
        local.cloudIds.put(remote.server, remote.remoteId); repo.merge(Collections.singletonList(local), false);
        java.nio.file.Files.write(repo.audio(local).toPath(), "changed".getBytes(StandardCharsets.UTF_8));
        repo.toggleFavorite(local.key); Repository.Playlist list = repo.createPlaylist("Keep link"); repo.addToPlaylist(local.key, list.id);
        repo.checkInvalidSongs(); awaitInvalidScan();
        Song retained = repo.song(local.key); assertNotNull(retained); assertFalse(retained.local()); assertTrue(retained.favorite);
        assertEquals(remote.remoteId, retained.sourceId(remote.server)); assertEquals(Collections.singletonList(local.key), list.keys);
        assertFalse(repo.audio(local).exists());
    }
    @Test public void scanDoesNotRemoveAFileRestoredBeforeCleanup() throws Exception {
        Song remote = fixture(); Song local = remote.copy(); local.key = "local-" + local.sha256; local.server = ""; local.remoteId = "";
        repo.merge(Collections.singletonList(local), false);
        final Runnable[] finish = new Runnable[1];
        repo.storageCleaner = (stopping, all, completion) -> finish[0] = completion;
        repo.checkInvalidSongs();
        for (int i = 0; i < 500 && finish[0] == null; i++) { Thread.sleep(10); Shadows.shadowOf(Looper.getMainLooper()).idle(); }
        assertNotNull(finish[0]);
        java.nio.file.Files.write(repo.audio(local).toPath(), "fixture".getBytes(StandardCharsets.UTF_8));
        finish[0].run();
        assertNotNull(repo.song(local.key)); assertTrue(repo.audio(local).exists()); assertFalse(repo.checkingInvalidSongs);
    }
    @Test public void clearingServerCacheKeepsImportedMusicFavoritesAndPlaylistReferences() throws Exception {
        Song remote = fixture(), local = remote.copy(); local.server = ""; local.remoteId = ""; local.key = "local-" + local.sha256;
        repo.merge(Collections.singletonList(local), false);
        java.nio.file.Files.copy(repo.audio(remote).toPath(), repo.audio(local).toPath());
        repo.toggleFavorite(remote.key); Repository.Playlist list = repo.createPlaylist("Keep"); repo.addToPlaylist(remote.key, list.id); repo.addToPlaylist(local.key, list.id);
        repo.clearDownloaded();
        assertFalse(repo.audio(remote).exists()); assertTrue(repo.audio(local).exists()); assertTrue(repo.song(remote.key).favorite);
        assertEquals(Arrays.asList(remote.key, local.key), repo.playlist(list.id).keys);
    }
    @Test public void radioRouteErrorKeepsHealthyCatalogOnlineWhileAuthAndNetworkFailuresDisconnect() throws Exception {
        fixture(); repo.online = true;
        repo.playbackRequestFailed(new ApiClient.Failure(405, "服务器电台接口未启用（HTTP 405）"));
        assertTrue(repo.online); assertTrue(repo.status.contains("405"));
        repo.playbackRequestFailed(new org.json.JSONException("invalid response"));
        assertTrue(repo.online);
        repo.playbackRequestFailed(new ApiClient.Failure(401, "认证失败"));
        assertFalse(repo.online);
        repo.online = true; repo.playbackRequestFailed(new java.net.SocketTimeoutException());
        assertFalse(repo.online);
    }
    @Test public void sharedPlaylistsKeepOrderCacheAndServerScopeAndPlayFromTheirOwnQueue() throws Exception {
        Song first = fixture(), second = first.copy(); second.remoteId = UUID.randomUUID().toString(); second.key = Core.songKey(second.server, second.remoteId); second.title = "Second song";
        repo.merge(Collections.singletonList(second), false);
        String id = UUID.randomUUID().toString();
        OnlinePlaylist list = OnlinePlaylist.parse(new org.json.JSONObject().put("id", id).put("name", "在线放松").put("trackIds", new org.json.JSONArray(Arrays.asList(second.remoteId, first.remoteId))), first.server);
        repo.mergeOnlinePlaylists(first.server, Collections.singletonList(list));
        assertEquals(Arrays.asList(second.key, first.key), keys(repo.onlinePlaylistSongs(id)));
        repo.markOffline("Offline"); assertEquals(Collections.singletonList(first.key), keys(repo.onlinePlaylistSongs(id)));
        Repository.Playlist local = repo.createPlaylist("Local"); assertNotEquals(local.id, list.id);
        repo.disk.submit(() -> {}).get(5, TimeUnit.SECONDS);
        Repository restored = new Repository(RuntimeEnvironment.getApplication());
        try { assertEquals("在线放松", restored.onlinePlaylists().get(0).name); assertEquals(Collections.singletonList(first.key), keys(restored.onlinePlaylistSongs(id))); }
        finally { restored.network.shutdownNow(); restored.disk.shutdownNow(); }
        repo.mergeOnlinePlaylists("https://other.test", Collections.emptyList()); assertEquals(1, repo.onlinePlaylists().size());
        ServiceController<PlaybackService> playback = Robolectric.buildService(PlaybackService.class).create();
        Shadows.shadowOf(RuntimeEnvironment.getApplication()).setComponentNameAndServiceForBindService(new ComponentName(repo.context, PlaybackService.class), playback.get().onBind(new Intent(repo.context, PlaybackService.class)));
        ActivityController<MainActivity> controller = Robolectric.buildActivity(MainActivity.class).setup();
        try {
            View root = controller.get().getWindow().getDecorView(); ((View)text(root, "歌单").getParent()).performClick();
            assertNotNull(text(root, "在线歌单")); text(root, "在线放松  ·  2 首").performClick();
            assertNotNull(text(root, "在线放松")); assertNotNull(text(root, "在线歌单 · 1 首可播放 · 共 2 首"));
            text(root, "▶ 播放歌单").performClick();
            Intent started; boolean played = false;
            while ((started = Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedService()) != null) if (PlaybackService.PLAY.equals(started.getAction())) { assertEquals(Collections.singletonList(first.key), started.getStringArrayListExtra("queue")); played = true; }
            assertTrue("Selected shared playlist queues its cached song", played);
        } finally { controller.pause().stop().destroy(); playback.destroy(); }
    }
    @Test public void refreshedServerOrderControlsPlaylistRowsPlaybackQueueAndNextSong() throws Exception {
        Song first = fixture(), second = first.copy(); second.remoteId = UUID.randomUUID().toString(); second.key = Core.songKey(second.server, second.remoteId); second.title = "Second";
        repo.merge(Collections.singletonList(second), false);
        java.nio.file.Files.copy(repo.audio(first).toPath(), repo.audio(second).toPath());
        String id = UUID.randomUUID().toString();
        java.util.function.Function<List<String>, OnlinePlaylist> ordered = ids -> {
            try { return OnlinePlaylist.parse(new org.json.JSONObject().put("id", id).put("name", "排序测试").put("trackIds", new org.json.JSONArray(ids)), first.server); }
            catch (Exception error) { throw new AssertionError(error); }
        };
        repo.mergeOnlinePlaylists(first.server, Collections.singletonList(ordered.apply(Arrays.asList(first.remoteId, second.remoteId))));
        ServiceController<PlaybackService> playback = Robolectric.buildService(PlaybackService.class).create();
        Shadows.shadowOf(RuntimeEnvironment.getApplication()).setComponentNameAndServiceForBindService(new ComponentName(repo.context, PlaybackService.class), playback.get().onBind(new Intent(repo.context, PlaybackService.class)));
        ActivityController<MainActivity> controller = Robolectric.buildActivity(MainActivity.class).setup();
        try {
            View root = controller.get().getWindow().getDecorView(); ((View)text(root, "歌单").getParent()).performClick(); text(root, "排序测试  ·  2 首").performClick();
            repo.mergeOnlinePlaylists(first.server, Collections.singletonList(ordered.apply(Arrays.asList(second.remoteId, first.remoteId))));
            assertEquals(Arrays.asList(second.key, first.key), keys(repo.onlinePlaylistSongs(id)));
            repo.mode = Core.Mode.SHUFFLE; text(root, "▶ 播放歌单").performClick();
            Intent intent, command = null;
            while ((intent = Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedService()) != null) if (PlaybackService.PLAY.equals(intent.getAction())) command = intent;
            assertNotNull(command); assertEquals(Core.Mode.LOOP, repo.mode);
            assertEquals(Arrays.asList(second.key, first.key), command.getStringArrayListExtra("queue"));
            playback.get().onStartCommand(command, 0, 1); assertEquals(second.key, playback.get().currentKey);
            playback.get().onStartCommand(new Intent(repo.context, PlaybackService.class).setAction(PlaybackService.NEXT), 0, 2);
            assertEquals(first.key, playback.get().currentKey);
            repo.disk.submit(() -> {}).get(5, TimeUnit.SECONDS);
            Repository restored = new Repository(RuntimeEnvironment.getApplication());
            try { assertEquals(Arrays.asList(second.key, first.key), keys(restored.onlinePlaylistSongs(id))); }
            finally { restored.network.shutdownNow(); restored.disk.shutdownNow(); }
        } finally { controller.pause().stop().destroy(); playback.destroy(); }
    }
    private List<String> keys(List<Song> songs) { List<String> keys = new ArrayList<>(); for (Song song : songs) keys.add(song.key); return keys; }
    private void awaitRefresh() throws Exception {
        for (int i = 0; i < 300 && repo.refreshing; i++) { Thread.sleep(10); Shadows.shadowOf(Looper.getMainLooper()).idle(); }
        assertFalse("Refresh completes", repo.refreshing);
    }
    @Test public void unavailablePlaylistEndpointRetainsHealthyCatalogAndLastList() throws Exception {
        try (HttpFixture server = new HttpFixture()) {
            // Refresh behavior uses a loopback fixture without the OS keystore;
            // the realHttpRequests test separately verifies Bearer authentication.
            server.allowAnonymous = true;
            repo.saveSettings(server.base, true, "", false); awaitRefresh();
            assertTrue(repo.online); assertEquals(1, repo.onlinePlaylists().size()); assertEquals(server.id, repo.onlinePlaylists().get(0).trackIds.get(0));
            server.playlistFailure = true; repo.refresh(); awaitRefresh();
            assertTrue(repo.online); assertEquals(1, repo.onlinePlaylists().size()); assertTrue(repo.playlistStatus.contains("405"));
        }
    }
    @Test public void enqueueWithNoCurrentSongDoesNotCrashOrStartPlayback() throws Exception {
        Song song = fixture(); ServiceController<PlaybackService> controller = Robolectric.buildService(PlaybackService.class).create(); PlaybackService service = controller.get();
        try {
            service.onStartCommand(new Intent(repo.context, PlaybackService.class).setAction(PlaybackService.ENQUEUE).putExtra("key", song.key), 0, 1);
            assertEquals(song.key, service.currentKey); assertFalse(service.playing); assertFalse(service.loading);
            assertEquals(Collections.singletonList(song.key), repo.lastQueue);
        } finally { controller.destroy(); }
    }
    @Test public void cachedPlaybackDoesNotReadInvalidCredentialsAndStopCancelsPendingPreparation() throws Exception {
        Song song = fixture();
        String tokenKey = "token_" + Core.hash(repo.credentials.server().getBytes(StandardCharsets.UTF_8));
        repo.context.getSharedPreferences("connection", Context.MODE_PRIVATE).edit().putString(tokenKey, "not-a-valid-encrypted-token").commit();
        ServiceController<PlaybackService> controller = Robolectric.buildService(PlaybackService.class).create(); PlaybackService service = controller.get();
        try {
            service.onStartCommand(new Intent(repo.context, PlaybackService.class).setAction(PlaybackService.PLAY).putExtra("key", song.key).putStringArrayListExtra("queue", new ArrayList<>(Collections.singletonList(song.key))), 0, 1);
            assertTrue(service.loading); assertFalse(service.message.contains("重新输入"));
            service.onStartCommand(new Intent(repo.context, PlaybackService.class).setAction(PlaybackService.STOP), 0, 2);
            Thread.sleep(100); Shadows.shadowOf(Looper.getMainLooper()).idle();
            assertFalse(service.loading); assertFalse(service.playing); assertEquals(0, service.position()); assertEquals(0, repo.song(song.key).plays);
            repo.disk.submit(() -> {}).get(5, TimeUnit.SECONDS);
            String saved = new String(java.nio.file.Files.readAllBytes(new File(repo.context.getFilesDir(), "library.json").toPath()), StandardCharsets.UTF_8);
            assertFalse(saved.contains("not-a-valid-encrypted-token"));
        } finally { controller.destroy(); }
    }
    @Test public void realHttpRequestsAuthenticateListRadioAndAudioAndRejectRedirects() throws Exception {
        try (HttpFixture server = new HttpFixture()) {
            ApiClient client = new ApiClient(); ApiClient.Connection settings = new ApiClient.Connection(server.base, "fixture-token", 0);
            try {
                List<Song> songs = client.list(settings); assertEquals(1, songs.size()); assertEquals(server.id, songs.get(0).remoteId);
                assertEquals(Collections.singletonList(server.id), client.playlists(settings).get(0).trackIds);
                assertEquals(server.id, client.radio(settings, server.id).remoteId); assertEquals("/api/music/tracks/radio?exclude=" + server.id, server.lastPath);
                File destination = new File(repo.context.getFilesDir(), "http-test.mp3"); client.download(settings, songs.get(0), destination, null);
                assertArrayEquals(server.audio, java.nio.file.Files.readAllBytes(destination.toPath())); assertTrue(destination.delete());
                byte[] ranged = new byte[7]; assertEquals(7, client.readRange(settings, songs.get(0), 3, ranged, 0, ranged.length));
                assertArrayEquals(Arrays.copyOfRange(server.audio, 3, 10), ranged);
                try { client.readRange(new ApiClient.Connection(server.base, "wrong", 0), songs.get(0), 0, ranged, 0, 7); fail("Range must require a token"); }
                catch (ApiClient.Failure expected) { assertEquals(401, expected.status); }
                server.redirectAudio = true;
                try { client.readRange(settings, songs.get(0), 0, ranged, 0, 7); fail("Range redirects must be rejected"); }
                catch (ApiClient.Failure expected) { assertEquals(0, server.leaked); }
                server.redirectAudio = false;
                File streamed = new File(repo.context.getFilesDir(), "progressive-test.mp3");
                try (ProgressiveCache cache = new ProgressiveCache(streamed, songs.get(0).size, songs.get(0).sha256)) {
                    client.downloadProgressively(settings, songs.get(0), cache, null);
                    assertArrayEquals(server.audio, java.nio.file.Files.readAllBytes(streamed.toPath()));
                }
                assertTrue(streamed.delete());
                server.slowAudio = true;
                ExecutorService downloader = Executors.newSingleThreadExecutor(); CountDownLatch firstBytes = new CountDownLatch(1);
                try (ProgressiveCache cache = new ProgressiveCache(streamed, songs.get(0).size, songs.get(0).sha256)) {
                    Future<?> loading = downloader.submit(() -> { try { client.downloadProgressively(settings, songs.get(0), cache, bytes -> firstBytes.countDown()); } catch (IOException error) { throw new UncheckedIOException(error); } });
                    assertTrue(firstBytes.await(3, TimeUnit.SECONDS));
                    byte[] early = new byte[4]; assertEquals(4, cache.readAt(0, early, 0, 4));
                    assertFalse("Audio bytes are readable while the authenticated download is still running", loading.isDone());
                    assertFalse("Incomplete audio is not advertised as an offline cache", streamed.exists());
                    loading.get(3, TimeUnit.SECONDS); assertArrayEquals(server.audio, java.nio.file.Files.readAllBytes(streamed.toPath()));
                } finally { downloader.shutdownNow(); server.slowAudio = false; }
                assertTrue(streamed.delete());
                server.empty = true; assertNull(client.radio(settings, null)); server.empty = false;
                try { client.list(new ApiClient.Connection(server.base, "wrong", 0)); fail("Wrong token should fail"); } catch (ApiClient.Failure expected) { assertTrue(expected.getMessage().contains("认证")); }
                server.redirect = true;
                try { client.radio(settings, null); fail("Redirect should fail"); } catch (ApiClient.Failure expected) { assertEquals(0, server.leaked); }
            } finally { client.cancelAll(); }
        }
    }
    private void awaitStorage() throws Exception {
        for (int i = 0; i < 500 && repo.storageBusy; i++) { Thread.sleep(10); Shadows.shadowOf(Looper.getMainLooper()).idle(); }
        assertFalse("Storage operation completes", repo.storageBusy);
    }
    @Test public void songAndPlaylistUploadsLinkOriginalsAndRemainIdempotent() throws Exception {
        try (HttpFixture server = new HttpFixture()) {
            server.allowAnonymous = true; repo.credentials.save(server.base, false, "", false);
            Song existing = Song.remote(new org.json.JSONObject(server.json), server.base); repo.merge(Collections.singletonList(existing), false); java.nio.file.Files.write(repo.audio(existing).toPath(), server.audio);
            Song local = Song.remote(new org.json.JSONObject(server.json), server.base); local.server = ""; local.remoteId = ""; local.key = "local-" + local.sha256;
            repo.merge(Collections.singletonList(local), false); java.nio.file.Files.write(repo.audio(local).toPath(), server.audio);
            Repository.Playlist list = repo.createPlaylist("Upload list"); repo.addToPlaylist(local.key, list.id);
            repo.uploadToCloud(local.key, null); awaitStorage();
            assertEquals("Linked original replaces duplicate cloud row", 1, repo.all().size());
            assertEquals(server.id, repo.song(local.key).sourceId(server.base)); assertTrue(repo.cached(local)); assertTrue(repo.song(local.key).hasCloud());
            repo.uploadToCloud(local.key, null); awaitStorage(); assertEquals(1, server.uploads);
            repo.uploadToCloud(null, list.id); awaitStorage();
            assertEquals(list.id, repo.onlinePlaylists().get(0).id); assertEquals(Collections.singletonList(server.id), repo.onlinePlaylists().get(0).trackIds);
            assertEquals(Collections.singletonList(local.key), keys(repo.onlinePlaylistSongs(list.id)));
            assertEquals(1, repo.all().size());
            repo.disk.submit(() -> {}).get(5, TimeUnit.SECONDS);
            Repository restored = new Repository(repo.context);
            try { assertEquals(server.id, restored.song(local.key).sourceId(server.base)); } finally { restored.network.shutdownNow(); restored.disk.shutdownNow(); }
        }
    }
    @Test public void uploadShowsProgressAndDoesNotBlockChangingSongs() throws Exception {
        try (HttpFixture server = new HttpFixture()) {
            server.allowAnonymous = true; server.slowUpload = true; repo.credentials.save(server.base, false, "", false);
            Song first = Song.remote(new org.json.JSONObject(server.json), server.base); first.server = ""; first.remoteId = ""; first.key = "local-" + first.sha256;
            Song second = fixture();
            repo.merge(Collections.singletonList(first), false); java.nio.file.Files.write(repo.audio(first).toPath(), server.audio);
            ServiceController<PlaybackService> controller = Robolectric.buildService(PlaybackService.class).create(); PlaybackService service = controller.get();
            try {
                repo.uploadToCloud(first.key, null);
                final int[] catalogChanges = {0}, progressChanges = {0};
                Repository.Listener observer = new Repository.Listener() {
                    @Override public void changed(boolean settingsChanged) { catalogChanges[0]++; }
                    @Override public void progressChanged() { progressChanges[0]++; }
                };
                repo.observe(observer);
                for (int i = 0; i < 100 && repo.uploadPercent < 100; i++) { Thread.sleep(10); Shadows.shadowOf(Looper.getMainLooper()).idle(); }
                assertTrue(repo.uploading); assertEquals(100, repo.uploadPercent); assertTrue(repo.status.contains("等待服务器处理"));
                assertTrue("Progress updates must reach the UI", progressChanges[0] > 0);
                assertEquals("Progress alone must not rebuild the catalog", 0, catalogChanges[0]);
                repo.remove(observer);
                service.onStartCommand(new Intent(repo.context, PlaybackService.class).setAction(PlaybackService.PLAY).putExtra("key", first.key).putStringArrayListExtra("queue", new ArrayList<>(Arrays.asList(first.key, second.key))), 0, 1);
                service.onStartCommand(new Intent(repo.context, PlaybackService.class).setAction(PlaybackService.NEXT), 0, 2);
                assertEquals("Uploading must not block next song", second.key, service.currentKey);
                awaitStorage(); assertEquals(-1, repo.uploadPercent); assertFalse(repo.uploading);
            } finally { controller.destroy(); }
        }
    }
    @Test public void deletionFailureRetainsCacheAndSuccessCleansAllReferences() throws Exception {
        try (HttpFixture server = new HttpFixture()) {
            server.allowAnonymous = true; repo.credentials.save(server.base, false, "", false);
            Song remote = Song.remote(new org.json.JSONObject(server.json), server.base); repo.merge(Collections.singletonList(remote), false);
            java.nio.file.Files.write(repo.audio(remote).toPath(), server.audio); Repository.Playlist list = repo.createPlaylist("Delete"); repo.addToPlaylist(remote.key, list.id);
            server.failDelete = true; repo.deleteSong(remote, true); awaitStorage(); assertNotNull(repo.song(remote.key)); assertTrue(repo.cached(remote));
            server.failDelete = false; repo.deleteSong(remote, true); awaitStorage(); assertNull(repo.song(remote.key)); assertFalse(repo.audio(remote).exists()); assertTrue(list.keys.isEmpty());
        }
    }
    @Test public void authoritativeRefreshClearsDeletedCloudCacheButKeepsLocalImports() throws Exception {
        try (HttpFixture server = new HttpFixture()) {
            server.allowAnonymous = true; repo.credentials.save(server.base, true, "", false);
            Song remote = Song.remote(new org.json.JSONObject(server.json), server.base); repo.merge(Collections.singletonList(remote), false); java.nio.file.Files.write(repo.audio(remote).toPath(), server.audio);
            Song local = remote.copy(); local.server = ""; local.remoteId = ""; local.key = "local-" + local.sha256; local.cloudIds.put(server.base, server.id); repo.merge(Collections.singletonList(local), false); java.nio.file.Files.write(repo.audio(local).toPath(), server.audio);
            server.emptyCatalog = true; repo.refresh(); awaitRefresh(); awaitStorage();
            assertNull(repo.song(remote.key)); assertFalse(repo.audio(remote).exists()); assertNotNull(repo.song(local.key)); assertTrue(repo.audio(local).exists()); assertFalse(repo.song(local.key).hasCloud());
        }
    }
    @Test public void clearingCacheWaitsForCancelledWriterAndPreservesImportedOriginal() throws Exception {
        Song remote = fixture(); final Runnable[] finish = new Runnable[1];
        repo.storageCleaner = (stopping, allCaches, completion) -> { assertTrue(allCaches); assertTrue(stopping.contains(remote.key)); finish[0] = completion; };
        repo.clearDownloaded(); assertTrue(repo.storageBusy); assertTrue(repo.audio(remote).exists());
        java.nio.file.Files.write(repo.audio(remote).toPath(), "late writer".getBytes(StandardCharsets.UTF_8));
        finish[0].run(); assertFalse(repo.storageBusy); assertFalse(repo.audio(remote).exists()); assertNotNull(repo.song(remote.key));
    }
    private static final class HttpFixture implements AutoCloseable {
        final java.net.ServerSocket server;
        final String base, id = UUID.randomUUID().toString();
        final byte[] audio = "generated fixture bytes".getBytes(StandardCharsets.UTF_8);
        final String json;
        volatile boolean redirect, redirectAudio, slowAudio, slowUpload, empty, closed, playlistFailure, allowAnonymous, failDelete, emptyCatalog;
        volatile int uploads;
        volatile int leaked;
        volatile String lastPath;
        HttpFixture() throws IOException {
            server = new java.net.ServerSocket(0, 20, java.net.InetAddress.getByName("127.0.0.1"));
            base = "http://127.0.0.1:" + server.getLocalPort();
            json = "{\"id\":\"" + id + "\",\"title\":\"Fixture\",\"artist\":\"Test\",\"album\":\"Test\",\"duration\":12,\"extension\":\"mp3\",\"sha256\":\"" + Core.hash(audio) + "\",\"size\":" + audio.length + ",\"uploadedAt\":\"2026-11-12T00:00:00Z\"}";
            Thread thread = new Thread(() -> {
                while (!closed) {
                    try (java.net.Socket socket = server.accept()) { serve(socket); }
                    catch (IOException ignored) { if (closed) return; }
                }
            }, "sonora-http-fixture"); thread.setDaemon(true); thread.start();
        }
        private void serve(java.net.Socket socket) throws IOException {
            socket.setSoTimeout(3000); BufferedReader input = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
            String first = input.readLine(); if (first == null) return;
            String method = first.split(" ")[0], path = first.split(" ")[1], authorization = "", range = ""; int length = 0; boolean chunked = false; lastPath = path;
            String line; while ((line = input.readLine()) != null && !line.isEmpty()) {
                String lower = line.toLowerCase(Locale.ROOT);
                if (lower.startsWith("range:")) range = line.substring(line.indexOf(':') + 1).trim();
                if (lower.startsWith("authorization:")) authorization = line.substring(line.indexOf(':') + 1).trim();
                if (lower.startsWith("content-length:")) length = Integer.parseInt(line.substring(line.indexOf(':') + 1).trim());
                if (lower.startsWith("transfer-encoding:") && lower.contains("chunked")) chunked = true;
            }
            StringBuilder requestBody = new StringBuilder();
            if (chunked) { while (true) { int count = Integer.parseInt(input.readLine(), 16); if (count == 0) { input.readLine(); break; } char[] chunk = new char[count]; int read = 0; while (read < count) read += input.read(chunk, read, count - read); requestBody.append(chunk); input.readLine(); } }
            else { char[] chunk = new char[length]; int read = 0; while (read < length) read += input.read(chunk, read, length - read); requestBody.append(chunk); }
            int code = 200; String location = ""; byte[] body;
            if (path.startsWith("/should-not")) { leaked++; code = 500; body = new byte[0]; }
            else if (!authorization.equals("Bearer fixture-token") && !(allowAnonymous && authorization.isEmpty())) { code = 401; body = new byte[0]; }
            else if (path.endsWith("/audio") && redirectAudio) { code = 302; location = "Location: " + base + "/should-not-be-requested\r\n"; body = new byte[0]; }
            else if (path.endsWith("/audio") && !range.isEmpty()) {
                String[] limits = range.substring("bytes=".length()).split("-"); int from = Integer.parseInt(limits[0]), to = Integer.parseInt(limits[1]);
                code = 206; location = "Content-Range: bytes " + from + "-" + to + "/" + audio.length + "\r\n"; body = Arrays.copyOfRange(audio, from, to + 1);
            }
            else if (method.equals("DELETE")) { code = failDelete ? 503 : 204; body = new byte[0]; }
            else if (method.equals("POST") && path.startsWith("/api/music/tracks?")) { uploads++; code = 201; body = json.getBytes(StandardCharsets.UTF_8); }
            else if (method.equals("POST") && path.equals("/api/music/playlists")) {
                try { org.json.JSONObject value = new org.json.JSONObject(requestBody.toString()); body = value.put("trackIds", new org.json.JSONArray()).toString().getBytes(StandardCharsets.UTF_8); code = 201; }
                catch (Exception e) { throw new IOException(e); }
            }
            else if ((method.equals("POST") || method.equals("PUT")) && path.startsWith("/api/music/playlists/")) {
                try { org.json.JSONObject value = new org.json.JSONObject(requestBody.toString()); body = value.put("id", path.split("/")[4]).put("name", "Upload list").toString().getBytes(StandardCharsets.UTF_8); }
                catch (Exception e) { throw new IOException(e); }
            }
            else if (path.equals("/api/music/tracks") && emptyCatalog) body = "[]".getBytes(StandardCharsets.UTF_8);
            else if (path.startsWith("/api/music/tracks/radio") && redirect) { code = 302; location = "Location: " + base + "/should-not-be-requested\r\n"; body = new byte[0]; }
            else if (path.startsWith("/api/music/tracks/radio") && empty) { code = 204; body = new byte[0]; }
            else if (path.equals("/api/music/playlists") && playlistFailure) { code = 405; body = new byte[0]; }
            else if (path.equals("/api/music/playlists")) body = ("[{\"id\":\"10000000-0000-0000-0000-000000000001\",\"name\":\"Shared\",\"trackIds\":[\"" + id + "\"]}]").getBytes(StandardCharsets.UTF_8);
            else body = path.endsWith("/audio") ? audio : (path.contains("/radio") ? json : "[" + json + "]").getBytes(StandardCharsets.UTF_8);
            if (slowUpload && method.equals("POST") && path.startsWith("/api/music/tracks?")) {
                try { Thread.sleep(500); } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
            }
            String headers = "HTTP/1.1 " + code + " Test\r\nContent-Length: " + body.length + "\r\n" + location + "Connection: close\r\n\r\n";
            OutputStream out = socket.getOutputStream(); out.write(headers.getBytes(StandardCharsets.US_ASCII));
            if (slowAudio && path.endsWith("/audio") && range.isEmpty() && code == 200 && body.length > 4) {
                out.write(body, 0, 4); out.flush();
                try { Thread.sleep(500); } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
                out.write(body, 4, body.length - 4);
            } else out.write(body);
            out.flush();
        }
        @Override public void close() throws IOException { closed = true; server.close(); }
    }
}
