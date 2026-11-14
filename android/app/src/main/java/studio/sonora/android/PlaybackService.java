package studio.sonora.android;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.media.*;
import android.media.session.*;
import android.os.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;

/** Playback belongs to the service so navigation and a locked screen do not interrupt audio. */
public final class PlaybackService extends Service implements Repository.Listener {
    public static final String PLAY = "sonora.PLAY", RADIO = "sonora.RADIO", TOGGLE = "sonora.TOGGLE", NEXT = "sonora.NEXT",
            PREVIOUS = "sonora.PREVIOUS", STOP = "sonora.STOP", SEEK = "sonora.SEEK", ENQUEUE = "sonora.ENQUEUE";
    private static final String CHANNEL = "sonora.playback";
    private static final int NOTIFICATION = 7;
    public interface Listener { void playbackChanged(boolean songChanged); }
    public final class LocalBinder extends Binder { public PlaybackService service() { return PlaybackService.this; } }
    private final LocalBinder binder = new LocalBinder();
    private final List<Listener> listeners = new ArrayList<>();
    private final ArrayList<String> queue = new ArrayList<>();
    private final Random random = new Random();
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final ApiClient api = new ApiClient();
    private final ExecutorService cacheWorkers = Executors.newFixedThreadPool(2);
    private final Map<String, Transfer> transfers = new HashMap<>();
    private StreamReader streamReader;
    private volatile boolean destroyed;
    private final class Transfer {
        final Song song; final ApiClient.Connection settings; final ProgressiveCache cache; final ApiClient client = new ApiClient();
        final CountDownLatch done = new CountDownLatch(1);
        int readers; boolean finished;
        Transfer(Song song, ApiClient.Connection settings) throws IOException { this.song = song; this.settings = settings; cache = new ProgressiveCache(repo.audio(song), song.size, song.sha256); }
        void closeIfUnused() {
            if (finished && readers == 0) {
                transfers.remove(song.key, this);
                try { cache.close(); } catch (IOException ignored) { }
            }
        }
    }
    private final class StreamReader extends MediaDataSource {
        final Transfer transfer; final ApiClient ranges = new ApiClient(); volatile boolean closed; volatile IOException failure; boolean released;
        StreamReader(Transfer transfer) { this.transfer = transfer; transfer.readers++; }
        @Override public int readAt(long position, byte[] buffer, int offset, int size) throws IOException {
            try {
                if (closed) throw new InterruptedIOException("读取已取消");
                if (position >= transfer.song.size) return -1;
                if (transfer.cache.contains(position)) return transfer.cache.readAt(position, buffer, offset, size, () -> closed);
                return ranges.readRange(transfer.settings, transfer.song, position, buffer, offset, size);
            } catch (IOException error) { if (!closed) failure = error; throw error; }
        }
        @Override public long getSize() { return transfer.song.size; }
        @Override public synchronized void close() {
            if (!closed) { closed = true; ranges.cancelAll(); transfer.cache.wakeReaders(); }
            if (Looper.myLooper() == Looper.getMainLooper()) releaseReference(); else main.post(this::releaseReference);
        }
        void releaseReference() {
            synchronized (this) { if (released) return; released = true; }
            transfer.readers--; transfer.closeIfUnused();
        }
    }
    private Transfer transfer(Song song, ApiClient.Connection settings) throws IOException {
        Transfer existing = transfers.get(song.key);
        if (existing != null && !existing.finished) return existing;
        Transfer created = new Transfer(song, settings); transfers.put(song.key, created);
        cacheWorkers.submit(() -> {
            try {
                created.client.downloadProgressively(settings, song, created.cache, bytes -> {
                    int percent = (int)(bytes * 100 / song.size);
                    main.post(() -> { if (streamReader != null && streamReader.transfer == created) { downloadPercent = percent; emit(false); } });
                });
                Repository.Metadata metadata = repo.readMetadata(song);
                main.post(() -> { repo.metadata(song.key, metadata); repo.emit(false); });
            } catch (IOException error) {
                created.cache.fail(error);
                main.post(() -> { if (streamReader != null && streamReader.transfer == created) { repo.playbackRequestFailed(error); message = repo.status; emit(false); } });
            } finally {
                created.done.countDown();
                if (destroyed) { try { created.cache.close(); } catch (IOException ignored) { } }
                else main.post(() -> { created.finished = true; created.closeIfUnused(); });
            }
        });
        return created;
    }
    private List<Transfer> cancelTransfers(Set<String> stopping) {
        List<Transfer> pending = new ArrayList<>();
        for (Transfer value : transfers.values()) if (stopping == null || stopping.contains(value.song.key)) pending.add(value);
        for (Transfer value : pending) { value.cache.fail(new InterruptedIOException("缓存已取消")); value.client.cancelAll(); }
        return pending;
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private Repository repo;
    private AudioManager audio;
    private AudioFocusRequest focus;
    private MediaSession session;
    private MediaPlayer player;
    private Future<?> task;
    private int generation;
    private boolean foreground, counted, autoResume;
    public boolean playing, loading, radio;
    public String currentKey = "", message = "选择一首喜欢的音乐";
    public int downloadPercent;
    public long duration, savedPosition;
    private long lastSave, lastNotification;
    private String lastRadioKey = "";

    private final BroadcastReceiver noisy = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { pause(false); }
    };
    private final Runnable clock = new Runnable() {
        @Override public void run() {
            if (playing) {
                emit(false); updateSession();
                if (SystemClock.elapsedRealtime() - lastSave > 10000) { persist(); lastSave = SystemClock.elapsedRealtime(); }
            }
            if (playing) main.postDelayed(this, 500);
        }
    };

    @Override public void onCreate() {
        super.onCreate(); repo = SonoraApp.repository(this); repo.observe(this);
        repo.storageCleaner = (stopping, allCaches, completion) -> {
            boolean stopCurrent = stopping.contains(currentKey) || (streamReader != null && (allCaches || stopping.contains(streamReader.transfer.song.key)));
            if (stopCurrent) cancel();
            List<Transfer> pending = cancelTransfers(allCaches ? null : stopping);
            if (stopCurrent) { main.removeCallbacks(clock); releasePlayer(); savedPosition = 0; playing = false; radio = false; leaveForeground(true); }
            worker.submit(() -> {
                for (Transfer value : pending) { try { value.done.await(); } catch (InterruptedException error) { Thread.currentThread().interrupt(); return; } }
                main.post(() -> {
                completion.run();
                queue.removeIf(key -> repo.song(key) == null);
                if (repo.song(currentKey) == null) { currentKey = ""; duration = 0; }
                persist(); updateSession(); emit(true);
            }); });
        };
        currentKey = repo.lastKey; savedPosition = repo.lastPosition; queue.addAll(repo.lastQueue);
        Song restored = current(); duration = restored == null ? 0 : restored.duration;
        audio = (AudioManager) getSystemService(AUDIO_SERVICE);
        AudioAttributes attributes = attributes();
        focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN).setAudioAttributes(attributes).setOnAudioFocusChangeListener(change -> {
            if (change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) { autoResume = playing; pause(true); }
            else if (change == AudioManager.AUDIOFOCUS_LOSS) { autoResume = false; pause(false); }
            else if (change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK) { if (player != null) player.setVolume(0.2f, 0.2f); }
            else if (change == AudioManager.AUDIOFOCUS_GAIN) {
                if (player != null) player.setVolume(1, 1);
                if (autoResume) { autoResume = false; resume(); }
            }
        }, main).build();
        NotificationChannel channel = new NotificationChannel(CHANNEL, "音乐播放", NotificationManager.IMPORTANCE_LOW);
        channel.setSound(null, null); channel.setShowBadge(false);
        getSystemService(NotificationManager.class).createNotificationChannel(channel);
        session = new MediaSession(this, "Sonora");
        session.setSessionActivity(PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        session.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { promote(); resume(); }
            @Override public void onPause() { pause(false); }
            @Override public void onStop() { stopPlayback(); }
            @Override public void onSkipToNext() { promote(); next(false); }
            @Override public void onSkipToPrevious() { promote(); previous(); }
            @Override public void onSeekTo(long position) { seek(position); }
        }, main);
        IntentFilter filter = new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, filter, Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(noisy, filter);
        main.post(clock);
    }
    private AudioAttributes attributes() { return new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build(); }
    @Override public IBinder onBind(Intent intent) { return binder; }
    public void observe(Listener listener) { if (!listeners.contains(listener)) listeners.add(listener); }
    public void remove(Listener listener) { listeners.remove(listener); }
    private void emit(boolean songChanged) { for (Listener listener : new ArrayList<>(listeners)) listener.playbackChanged(songChanged); }
    public Song current() { return repo.song(currentKey); }
    public long position() {
        try { return player != null && !loading ? player.getCurrentPosition() : savedPosition; }
        catch (IllegalStateException ignored) { return savedPosition; }
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || intent.getAction() == null) { stopSelf(); return START_NOT_STICKY; }
        if (repo.storageBusy && !repo.uploading && !STOP.equals(intent.getAction())) return START_NOT_STICKY;
        String action = intent.getAction();
        if (Arrays.asList(PLAY, RADIO, TOGGLE, NEXT, PREVIOUS).contains(action)) promote();
        switch (action) {
            case PLAY:
                radio = false; queue.clear();
                ArrayList<String> source = intent.getStringArrayListExtra("queue");
                if (source != null) for (String key : source) if (!queue.contains(key) && repo.song(key) != null) queue.add(key);
                String key = intent.getStringExtra("key");
                if (key != null && repo.song(key) != null) { if (!queue.contains(key)) queue.add(0, key); load(key, 0); }
                else { message = "歌曲已不可用，请刷新曲库"; idle(); }
                break;
            case RADIO: nextRadio(); break;
            case TOGGLE: if (playing || loading) pause(false); else resume(); break;
            case NEXT: next(false); break;
            case PREVIOUS: previous(); break;
            case SEEK: seek(intent.getLongExtra("position", 0)); break;
            case ENQUEUE: enqueue(intent.getStringExtra("key")); break;
            case STOP: stopPlayback(); break;
        }
        if (!playing && !loading) leaveForeground(false);
        return START_NOT_STICKY;
    }
    private void cancel() {
        generation++; if (task != null) task.cancel(true); task = null; api.cancelAll(); loading = false; downloadPercent = 0;
    }
    private void releasePlayer() {
        if (streamReader != null) { streamReader.close(); streamReader = null; }
        if (player != null) { player.setOnCompletionListener(null); player.setOnPreparedListener(null); player.setOnErrorListener(null); player.release(); player = null; }
        playing = false;
    }
    private void load(String key, long position) {
        if (repo.storageBusy && !repo.uploading) return;
        cancel(); releasePlayer(); counted = false; savedPosition = position; currentKey = key;
        Song song = current();
        if (song == null) { message = "歌曲已不可用"; idle(); return; }
        duration = song.duration; loading = true; message = repo.cached(song) ? "正在准备播放…" : "正在缓存歌曲…";
        if (radio) lastRadioKey = key;
        int attempt = generation, revision = repo.revision;
        promote(); emit(true); persist();
        ApiClient.Connection settings;
        try { settings = repo.cached(song) ? new ApiClient.Connection(repo.credentials.server(), "", repo.revision) : repo.connection(); }
        catch (Exception error) { loading = false; message = "请在设置中重新输入访问令牌"; idle(); return; }
        if (!repo.cached(song)) {
            if (!repo.credentials.enabled() || song.local() || !song.server.equals(settings.server)) { loading = false; message = "这首歌曲还未缓存，请连接对应服务器"; idle(); return; }
            try {
                streamReader = new StreamReader(transfer(song, settings));
                prepare(song, position, attempt);
            } catch (IOException error) { loading = false; message = "无法创建歌曲缓存"; idle(); }
            return;
        }
        task = worker.submit(() -> {
            Repository.Metadata metadata = repo.readMetadata(song);
            main.post(() -> { if (attempt == generation && revision == repo.revision) { repo.metadata(song.key, metadata); prepare(song, position, attempt); } });
        });
    }

    private void prepare(Song song, long position, int attempt) {
        try {
            MediaPlayer next = new MediaPlayer(); player = next;
            next.setAudioAttributes(attributes()); next.setWakeMode(this, PowerManager.PARTIAL_WAKE_LOCK);
            if (streamReader != null) next.setDataSource(streamReader);
            else next.setDataSource(repo.audio(song).getAbsolutePath());
            next.setOnPreparedListener(prepared -> {
                if (attempt != generation || player != prepared) return;
                loading = false; duration = prepared.getDuration(); savedPosition = Math.min(position, Math.max(0, duration - 100));
                if (savedPosition > 0) prepared.seekTo(savedPosition, MediaPlayer.SEEK_CLOSEST);
                startPrepared();
            });
            next.setOnCompletionListener(completed -> { if (player == completed && attempt == generation) { playing = false; next(true); } });
            next.setOnErrorListener((failed, what, extra) -> {
                if (player == failed && attempt == generation) {
                    IOException error = streamReader == null ? null : streamReader.failure;
                    loading = false; releasePlayer();
                    if (error != null) {
                        repo.playbackRequestFailed(error); message = repo.status;
                        if (ApiClient.requiresOffline(error)) {
                            if (radio) { offlineRadio(); return true; }
                            List<Song> available = repo.offline();
                            if (!available.isEmpty()) { queue.clear(); for (Song local : available) queue.add(local.key); load(queue.get(0), 0); return true; }
                        }
                    } else message = "无法解码这首音频，请尝试其他歌曲";
                    idle();
                }
                return true;
            });
            updateMetadata(); next.prepareAsync();
        } catch (Exception error) { loading = false; releasePlayer(); message = "无法打开音频，可能不支持此编码"; idle(); }
    }
    private void startPrepared() {
        if (player == null) return;
        promote();
        if (audio.requestAudioFocus(focus) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) { message = "其他应用正在占用音频，请稍后继续播放"; pause(false); return; }
        try {
            player.start(); playing = true; main.removeCallbacks(clock); main.postDelayed(clock, 500);
            message = radio ? (repo.online ? "我的电台 · 听完自动续播" : "离线电台 · 本地与缓存音乐") : "正在播放";
            if (!counted) { counted = true; repo.count(currentKey); }
            updateMetadata(); notifyState(); persist(); emit(true);
        } catch (IllegalStateException error) { playing = false; message = "暂时无法播放，请重新选择歌曲"; idle(); }
    }
    private void resume() {
        if (repo.storageBusy && !repo.uploading) return;
        autoResume = false;
        if (playing || loading) return;
        if (current() == null) {
            if (radio) { nextRadio(); return; }
            List<Song> choices = repo.available();
            if (choices.isEmpty()) { message = "请先连接服务器或导入本地音乐"; idle(); return; }
            queue.clear(); for (Song song : choices) queue.add(song.key); load(queue.get(0), 0); return;
        }
        if (player == null) load(currentKey, savedPosition);
        else {
            if (savedPosition >= duration - 100) { savedPosition = 0; player.seekTo(0); counted = false; }
            startPrepared();
        }
    }
    private void pause(boolean transientLoss) {
        boolean cancelledRadioFetch = loading && radio && current() == null;
        if (loading) { cancel(); releasePlayer(); }
        if (cancelledRadioFetch) radio = false;
        main.removeCallbacks(clock);
        savedPosition = position();
        if (player != null) { try { player.pause(); } catch (IllegalStateException ignored) {} }
        playing = false; message = radio ? "电台已暂停，可继续收听或换一首" : "已暂停";
        if (!transientLoss) { autoResume = false; audio.abandonAudioFocusRequest(focus); leaveForeground(false); }
        notifyState(); persist(); emit(false);
    }
    private void stopPlayback() {
        main.removeCallbacks(clock);
        cancel(); autoResume = false; releasePlayer(); savedPosition = 0; counted = false;
        audio.abandonAudioFocusRequest(focus); message = "已停止"; leaveForeground(true);
        session.setActive(false); updateSession(); persist(); emit(false); stopSelf();
    }
    public void clearDownloadedAudio() { repo.clearDownloaded(); }
    private void next(boolean automatic) {
        if (repo.storageBusy && !repo.uploading) return;
        if (radio) { nextRadio(); return; }
        Set<String> available = new HashSet<>(); for (Song song : repo.available()) available.add(song.key);
        int oldIndex = queue.indexOf(currentKey);
        queue.removeIf(key -> !available.contains(key));
        int index = queue.indexOf(currentKey);
        if (index < 0 && !queue.isEmpty()) { load(queue.get(Math.min(Math.max(0, oldIndex), queue.size() - 1)), 0); return; }
        int nextIndex = Core.nextIndex(queue.size(), index, repo.mode, automatic, random);
        if (nextIndex < 0) { savedPosition = duration; pause(false); }
        else load(queue.get(nextIndex), 0);
    }
    private void previous() {
        if (repo.storageBusy && !repo.uploading) return;
        if (radio || position() > 3000) { seek(0); return; }
        int index = queue.indexOf(currentKey);
        if (index > 0) load(queue.get(index - 1), 0);
        else if (!queue.isEmpty() && repo.mode == Core.Mode.LOOP) load(queue.get(queue.size() - 1), 0);
        else seek(0);
    }
    private void seek(long position) {
        savedPosition = Math.min(Math.max(0, position), Math.max(0, duration));
        if (player != null && !loading) { try { player.seekTo(savedPosition, MediaPlayer.SEEK_CLOSEST); } catch (IllegalStateException ignored) {} }
        updateSession(); persist(); emit(false);
    }
    private void enqueue(String key) {
        if (repo.storageBusy && !repo.uploading) return;
        if (repo.song(key) == null || Objects.equals(key, currentKey)) return;
        if (radio && loading) { cancel(); releasePlayer(); }
        radio = false; queue.remove(key); int cursor = queue.indexOf(currentKey);
        queue.add(Math.min(queue.size(), Math.max(0, cursor + 1)), key);
        if (current() == null) currentKey = key;
        persist(); emit(true);
    }
    private void nextRadio() {
        if (repo.storageBusy && !repo.uploading) return;
        boolean wasRadio = radio; Song previous = current() == null ? repo.song(lastRadioKey) : current();
        cancel(); releasePlayer(); currentKey = ""; queue.clear(); savedPosition = 0; duration = 0; radio = true;
        if (!repo.credentials.enabled() || (wasRadio && !repo.online && SystemClock.elapsedRealtime() - repo.lastNetworkAttempt < 30000)) { offlineRadio(); return; }
        ApiClient.Connection settings;
        try { settings = repo.connection(); } catch (Exception error) { message = "请在设置中重新输入访问令牌"; offlineRadio(); return; }
        String excluded = previous != null && previous.server.equals(settings.server) ? previous.remoteId : null;
        int attempt = generation; loading = true; message = "正在为你寻找下一首…"; repo.lastNetworkAttempt = SystemClock.elapsedRealtime();
        promote(); emit(true); persist();
        task = worker.submit(() -> {
            try {
                Song song = api.radio(settings, excluded);
                main.post(() -> {
                    if (attempt != generation || settings.revision != repo.revision) return;
                    loading = false;
                    if (song == null) { repo.online = true; repo.status = "在线模式 · 电台已连接"; repo.emit(false); radio = false; message = "服务器还没有歌曲，请先在管理页面上传音乐"; idle(); return; }
                    repo.status = "在线模式 · 电台收听中"; repo.merge(Collections.singletonList(song), false);
                    queue.clear(); queue.add(song.key); load(song.key, 0);
                });
            } catch (Exception error) {
                main.post(() -> { if (attempt == generation && settings.revision == repo.revision) { loading = false; repo.playbackRequestFailed(error); offlineRadio(); } });
            }
        });
    }
    private void offlineRadio() {
        List<Song> local = repo.offline(); List<String> choices = new ArrayList<>(); for (Song song : local) choices.add(song.key);
        String selected = Core.different(choices, lastRadioKey, random);
        if (selected == null) { radio = false; loading = false; message = "电台暂时不可用，请连接服务器或导入本地音乐"; idle(); return; }
        queue.clear(); queue.add(selected); load(selected, 0);
    }
    @Override public void changed(boolean settingsChanged) {
        Song normalized = repo.song(currentKey);
        if (normalized != null && !normalized.key.equals(currentKey)) {
            if (loading) { cancel(); message = "歌曲已关联本地副本，点播放继续"; }
            currentKey = normalized.key;
        }
        for (int i = 0; i < queue.size(); i++) { Song song = repo.song(queue.get(i)); if (song != null) queue.set(i, song.key); }
        LinkedHashSet<String> unique = new LinkedHashSet<>(queue); queue.clear(); queue.addAll(unique);
        if (settingsChanged) {
            boolean pending = loading; cancel(); radio = false;
            if (pending) { releasePlayer(); message = "连接设置已更新，请重新选择歌曲"; idle(); }
            emit(false);
        }
    }
    private void persist() { repo.playback(currentKey, position(), queue); }
    private PendingIntent control(String action) {
        Intent intent = new Intent(this, PlaybackService.class).setAction(action);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE;
        return STOP.equals(action) ? PendingIntent.getService(this, action.hashCode(), intent, flags) : PendingIntent.getForegroundService(this, action.hashCode(), intent, flags);
    }
    private Notification notification() {
        Song song = current();
        Notification.Builder builder = new Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(song == null ? "声屿 · 我的电台" : song.title)
                .setContentText(loading ? message : (song == null ? message : song.artist))
                .setContentIntent(session.getController().getSessionActivity()).setVisibility(Notification.VISIBILITY_PUBLIC)
                .setOnlyAlertOnce(true).setOngoing(playing || loading).setCategory(Notification.CATEGORY_TRANSPORT)
                .addAction(new Notification.Action.Builder(android.R.drawable.ic_media_previous, "上一首", control(PREVIOUS)).build())
                .addAction(new Notification.Action.Builder(playing || loading ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play, playing || loading ? "暂停" : "播放", control(TOGGLE)).build())
                .addAction(new Notification.Action.Builder(android.R.drawable.ic_media_next, "下一首", control(NEXT)).build())
                .addAction(new Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "停止", control(STOP)).build())
                .setDeleteIntent(control(STOP))
                .setStyle(new Notification.MediaStyle().setMediaSession(session.getSessionToken()).setShowActionsInCompactView(0, 1, 2));
        if (loading) builder.setProgress(100, downloadPercent, downloadPercent == 0);
        if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
        return builder.build();
    }
    private void promote() {
        session.setActive(true);
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        else startForeground(NOTIFICATION, notification());
        foreground = true;
    }
    private void leaveForeground(boolean remove) {
        if (foreground) stopForeground(remove ? STOP_FOREGROUND_REMOVE : STOP_FOREGROUND_DETACH);
        foreground = false;
        if (remove) getSystemService(NotificationManager.class).cancel(NOTIFICATION);
    }
    private void idle() { loading = false; playing = false; leaveForeground(true); updateSession(); emit(false); }
    private void notifyState() {
        updateSession();
        long now = SystemClock.elapsedRealtime();
        if (now - lastNotification > 350 || !loading) {
            lastNotification = now;
            if (session.isActive() && current() != null) getSystemService(NotificationManager.class).notify(NOTIFICATION, notification());
        }
    }
    private void updateMetadata() {
        Song song = current(); if (song == null) return;
        session.setMetadata(new MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE, song.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, song.artist).putString(MediaMetadata.METADATA_KEY_ALBUM, song.album)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, duration).build());
    }
    private void updateSession() {
        int state = loading ? PlaybackState.STATE_BUFFERING : (playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED);
        session.setPlaybackState(new PlaybackState.Builder().setActions(PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE | PlaybackState.ACTION_PLAY_PAUSE |
                        PlaybackState.ACTION_STOP | PlaybackState.ACTION_SKIP_TO_NEXT | PlaybackState.ACTION_SKIP_TO_PREVIOUS | PlaybackState.ACTION_SEEK_TO)
                .setState(state, position(), playing ? 1 : 0, SystemClock.elapsedRealtime()).build());
    }
    @Override public void onTaskRemoved(Intent rootIntent) { if (!playing && !loading) stopSelf(); }
    @Override public void onDestroy() {
        persist(); cancel(); releasePlayer(); destroyed = true;
        for (Transfer value : cancelTransfers(null)) if (value.done.getCount() == 0) { value.finished = true; value.closeIfUnused(); }
        cacheWorkers.shutdown(); repo.remove(this); repo.storageCleaner = null; worker.shutdownNow(); main.removeCallbacksAndMessages(null);
        audio.abandonAudioFocusRequest(focus); unregisterReceiver(noisy); session.release(); leaveForeground(true); super.onDestroy();
    }
}
