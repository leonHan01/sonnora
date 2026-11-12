package studio.sonora.android;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.*;
import android.graphics.drawable.ColorDrawable;
import android.media.AudioManager;
import android.net.Uri;
import android.os.*;
import android.text.*;
import android.view.*;
import android.widget.*;
import java.util.*;

public final class MainActivity extends Activity implements Repository.Listener, PlaybackService.Listener {
    private static final int LIBRARY = 0, RADIO = 1, PLAYLISTS = 2, SETTINGS = 3, IMPORT_AUDIO = 70;
    private Repository repo;
    private PlaybackService service;
    private boolean bound;
    private int tab, filter;
    private String query = "", playlistId;
    private boolean onlinePlaylistSelected;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private LinearLayout root, mini, navigation;
    private FrameLayout content;
    private final View[] pages = new View[4];
    private final TextView[] navLabels = new TextView[4];
    private final ImageView[] navIcons = new ImageView[4];
    private TextView connectionStatus, librarySummary, libraryEmpty, miniTitle, miniArtist, radioTitle, radioArtist, radioAlbum, radioHint, radioBadge, settingsStatus, cacheSize;
    private ProgressBar miniProgress;
    private Ui.Art miniArt, radioArt;
    private ImageButton miniPlay, radioHeart;
    private Button radioPlay;
    private final Button[] chips = new Button[3];
    private SongAdapter libraryAdapter, playlistAdapter;
    private LinearLayout playlistsBody;
    private TextView playlistEmpty;
    private TextView playlistTitle, playlistSummary;
    private EditText serverEdit, tokenEdit;
    private Switch onlineSwitch;
    private CheckBox clearToken;
    private Dialog fullPlayer;
    private Ui.Art fullArt;
    private TextView fullTitle, fullArtist, fullStatus, fullElapsed, fullDuration;
    private ImageButton fullPlay, fullHeart;
    private SeekBar fullSeek;
    private Button modeButton;
    private boolean seeking;

    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            service = ((PlaybackService.LocalBinder) binder).service(); service.observe(MainActivity.this); renderPlayback(true);
        }
        @Override public void onServiceDisconnected(ComponentName name) { service = null; }
    };
    private final Runnable refreshClock = new Runnable() {
        @Override public void run() { if (repo.credentials.enabled()) repo.refresh(); handler.postDelayed(this, 30000); }
    };
    @Override public void onCreate(Bundle state) {
        super.onCreate(state); repo = SonoraApp.repository(this); setVolumeControlStream(AudioManager.STREAM_MUSIC);
        getWindow().setStatusBarColor(Ui.BG); getWindow().setNavigationBarColor(Ui.BG);
        root = Ui.column(this); root.setBackgroundColor(Ui.BG); root.setFocusableInTouchMode(true); setContentView(root); applyInsets(root);
        buildHeader(); content = new FrameLayout(this); root.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
        buildMini(); buildNavigation(); tab = state == null ? 0 : state.getInt("tab", 0); selectTab(tab, false);
        if (Build.VERSION.SDK_INT >= 33) getOnBackInvokedDispatcher().registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, this::back);
    }
    private void applyInsets(View view) {
        view.setOnApplyWindowInsetsListener((target, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                target.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            } else target.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        view.requestApplyInsets();
    }
    @Override protected void onStart() {
        super.onStart(); repo.observe(this); bound = bindService(new Intent(this, PlaybackService.class), connection, Context.BIND_AUTO_CREATE);
        renderCatalog(); handler.post(refreshClock);
    }
    @Override protected void onStop() {
        handler.removeCallbacksAndMessages(null); repo.remove(this);
        if (service != null) service.remove(this);
        if (bound) { unbindService(connection); bound = false; } service = null;
        if (fullPlayer != null) fullPlayer.dismiss(); super.onStop();
    }
    @Override protected void onSaveInstanceState(Bundle out) { out.putInt("tab", tab); super.onSaveInstanceState(out); }
    private void back() { if (tab == PLAYLISTS && playlistId != null) { playlistId = null; rebuildPlaylists(); } else if (tab != LIBRARY) selectTab(LIBRARY, false); else finish(); }
    @Override public void onBackPressed() { back(); }
    private void buildHeader() {
        LinearLayout header = Ui.row(this); Ui.padding(header, 20, 10);
        ImageView logo = new ImageView(this); logo.setImageResource(R.drawable.ic_notification); logo.setImageTintList(ColorStateList.valueOf(Ui.BG)); logo.setBackground(Ui.round(this, Ui.ACCENT, 14)); Ui.padding(logo, 10, 10); LinearLayout.LayoutParams logoParams = new LinearLayout.LayoutParams(Ui.dp(this, 40), Ui.dp(this, 40)); logoParams.rightMargin = Ui.dp(this, 12); header.addView(logo, logoParams);
        LinearLayout brand = Ui.column(this); TextView title = Ui.text(this, "声屿", 22, Ui.TEXT); title.setTypeface(null, Typeface.BOLD);
        brand.addView(title); TextView english = Ui.text(this, "S O N O R A", 8, Ui.MUTED); brand.addView(english); header.addView(brand, Ui.weight());
        ImageButton refresh = Ui.icon(this, R.drawable.ic_refresh, "刷新在线曲库", v -> repo.refresh()); header.addView(refresh); root.addView(header);
        connectionStatus = Ui.text(this, repo.status, 11, Ui.MUTED); Ui.padding(connectionStatus, 24, 0); connectionStatus.setMaxLines(2); connectionStatus.setOnClickListener(v -> selectTab(SETTINGS, false)); root.addView(connectionStatus); root.addView(Ui.space(this, 8));
    }
    private void buildNavigation() {
        navigation = Ui.row(this); Ui.padding(navigation, 8, 7); navigation.setBackgroundColor(Ui.BG);
        int[] icons = {R.drawable.ic_library, R.drawable.ic_radio, R.drawable.ic_playlist, R.drawable.ic_settings};
        String[] labels = {"音乐", "电台", "歌单", "设置"};
        for (int index = 0; index < 4; index++) {
            int selected = index; LinearLayout item = Ui.column(this); item.setGravity(Gravity.CENTER); Ui.padding(item, 0, 5);
            ImageView icon = new ImageView(this); icon.setImageResource(icons[index]); item.addView(icon, new LinearLayout.LayoutParams(Ui.dp(this, 23), Ui.dp(this, 23)));
            TextView label = Ui.text(this, labels[index], 10, Ui.MUTED); LinearLayout.LayoutParams labelParams = new LinearLayout.LayoutParams(-2, -2); labelParams.topMargin = Ui.dp(this, 4); item.addView(label, labelParams);
            item.setContentDescription(labels[index]); item.setOnClickListener(v -> selectTab(selected, true)); item.setFocusable(true);
            navigation.addView(item, new LinearLayout.LayoutParams(0, Ui.dp(this, 56), 1)); navLabels[index] = label; navIcons[index] = icon;
        }
        root.addView(navigation);
    }
    private void selectTab(int selected, boolean user) {
        tab = selected;
        if (pages[selected] == null) {
            switch (selected) { case LIBRARY: pages[selected] = libraryPage(); break; case RADIO: pages[selected] = radioPage(); break; case PLAYLISTS: pages[selected] = playlistPage(); break; default: pages[selected] = settingsPage(); }
        }
        content.removeAllViews(); content.addView(pages[selected], new FrameLayout.LayoutParams(-1, -1));
        for (int i = 0; i < 4; i++) { int color = i == selected ? Ui.ACCENT : Ui.MUTED; navLabels[i].setTextColor(color); navIcons[i].setImageTintList(ColorStateList.valueOf(color)); }
        renderCatalog(); renderPlayback(false);
        if (user && selected == RADIO && (service == null || !service.radio)) command(PlaybackService.RADIO);
        if (selected != SETTINGS && getCurrentFocus() instanceof EditText) { ((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(root.getWindowToken(), 0); root.requestFocus(); }
    }
    private View libraryPage() {
        LinearLayout page = Ui.column(this); Ui.padding(page, 20, 12);
        TextView title = Ui.text(this, "音乐，随时在身边。", 25, Ui.TEXT); title.setTypeface(null, Typeface.BOLD); page.addView(title);
        librarySummary = Ui.text(this, "", 12, Ui.MUTED); page.addView(Ui.space(this, 7)); page.addView(librarySummary); page.addView(Ui.space(this, 18));
        EditText search = Ui.input(this, "搜索歌曲、歌手、专辑"); search.setCompoundDrawablesWithIntrinsicBounds(R.drawable.ic_search, 0, 0, 0); search.setCompoundDrawablePadding(Ui.dp(this, 10));
        page.addView(search, new LinearLayout.LayoutParams(-1, Ui.dp(this, 48)));
        search.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) { query = s.toString().trim().toLowerCase(Locale.ROOT); renderSongs(); }
            @Override public void afterTextChanged(Editable value) {}
        });
        LinearLayout filters = Ui.row(this); String[] names = {"全部音乐", "我的喜欢", "已缓存"};
        for (int i = 0; i < 3; i++) { int value = i; Button chip = Ui.button(this, names[i], false, v -> { filter = value; renderSongs(); }); chip.setTextSize(12); chip.setMinWidth(0); LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, Ui.dp(this, 44), 1); if (i > 0) lp.leftMargin = Ui.dp(this, 7); filters.addView(chip, lp); chips[i] = chip; }
        page.addView(Ui.space(this, 12)); page.addView(filters);
        LinearLayout actions = Ui.row(this); actions.addView(Ui.text(this, "为此刻，选一首。", 11, Ui.MUTED), Ui.weight());
        Button playAll = Ui.button(this, "▶ 播放全部", false, v -> { if (!libraryAdapter.values.isEmpty()) play(libraryAdapter.values.get(0), libraryAdapter.values); });
        playAll.setTextSize(12); actions.addView(playAll); page.addView(actions); page.addView(Ui.space(this, 6));
        FrameLayout listContainer = new FrameLayout(this); ListView list = list(); libraryAdapter = new SongAdapter(null); list.setAdapter(libraryAdapter);
        libraryEmpty = Ui.text(this, "连接服务器，发现喜欢的音乐。\n\n也可以在设置中导入本地歌曲。", 14, Ui.MUTED); libraryEmpty.setGravity(Gravity.CENTER); libraryEmpty.setLineSpacing(Ui.dp(this, 6), 1);
        listContainer.addView(libraryEmpty, new FrameLayout.LayoutParams(-1, -1)); listContainer.addView(list, new FrameLayout.LayoutParams(-1, -1)); list.setEmptyView(libraryEmpty);
        page.addView(listContainer, new LinearLayout.LayoutParams(-1, 0, 1)); return page;
    }
    private ListView list() { ListView list = new ListView(this); list.setDivider(null); list.setVerticalScrollBarEnabled(false); list.setSelector(new ColorDrawable(0x142c3c27)); return list; }
    private void renderSongs() {
        if (libraryAdapter == null) return;
        List<Song> available = repo.available(), filtered = new ArrayList<>(); int cached = 0;
        for (Song song : available) {
            if (song.cached) cached++;
            if (filter == 1 && !song.favorite || filter == 2 && !song.cached) continue;
            if (!(song.title + " " + song.artist + " " + song.album).toLowerCase(Locale.ROOT).contains(query)) continue;
            filtered.add(song);
        }
        librarySummary.setText(getString(R.string.music_summary, available.size(), cached)); libraryAdapter.replace(filtered);
        libraryEmpty.setText(!query.isEmpty() ? "没有找到匹配的音乐" : (filter == 1 ? "点击歌曲旁的爱心，留下喜欢。" : (filter == 2 ? "播放在线歌曲后，缓存会留在这里。" : "连接服务器，发现喜欢的音乐。\n\n也可以在设置中导入本地歌曲。")));
        for (int i = 0; i < 3; i++) { chips[i].setTextColor(i == filter ? Ui.ACCENT : Ui.MUTED); chips[i].setBackground(Ui.round(this, i == filter ? 0xff263020 : Ui.PANEL, 14)); }
    }
    private View radioPage() {
        LinearLayout outer = Ui.column(this);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); LinearLayout page = Ui.column(this); Ui.padding(page, 26, 20); page.setGravity(Gravity.CENTER_HORIZONTAL);
        TextView eyebrow = Ui.text(this, "YOUR PERSONAL RADIO", 9, Ui.ACCENT); eyebrow.setLetterSpacing(.2f); page.addView(eyebrow); page.addView(Ui.space(this, 10));
        TextView title = Ui.text(this, "我的电台", 30, Ui.TEXT); title.setTypeface(null, Typeface.BOLD); page.addView(title); page.addView(Ui.space(this, 9));
        page.addView(Ui.text(this, "把下一次心动，交给电台。", 12, Ui.MUTED)); page.addView(Ui.space(this, 26));
        radioArt = new Ui.Art(this, 190); page.addView(radioArt); page.addView(Ui.space(this, 18));
        radioBadge = Ui.text(this, "在线 / 离线收听", 10, Ui.ACCENT); page.addView(radioBadge); page.addView(Ui.space(this, 10));
        radioTitle = Ui.text(this, "下一首，刚好喜欢", 22, Ui.TEXT); radioTitle.setMaxLines(2); radioTitle.setGravity(Gravity.CENTER); radioTitle.setTypeface(null, Typeface.BOLD); page.addView(radioTitle);
        radioArtist = Ui.text(this, "", 14, Ui.MUTED); radioArtist.setGravity(Gravity.CENTER); page.addView(Ui.space(this, 8)); page.addView(radioArtist);
        radioAlbum = Ui.text(this, "", 11, Ui.MUTED); radioAlbum.setGravity(Gravity.CENTER); page.addView(Ui.space(this, 5)); page.addView(radioAlbum); page.addView(Ui.space(this, 15));
        LinearLayout extras = Ui.row(this); extras.setGravity(Gravity.CENTER); radioHeart = Ui.icon(this, R.drawable.ic_heart, "喜欢当前电台歌曲", v -> { if (service != null && service.current() != null) repo.toggleFavorite(service.currentKey); }); extras.addView(radioHeart);
        extras.addView(Ui.icon(this, R.drawable.ic_add_playlist, "加入歌单", v -> { if (service != null && service.current() != null) addToPlaylist(service.current()); })); page.addView(extras); page.addView(Ui.space(this, 12));
        LinearLayout controls = Ui.row(this); controls.setGravity(Gravity.CENTER); radioPlay = Ui.button(this, "开始收听", true, v -> { if (service != null && service.radio) command(PlaybackService.TOGGLE); else command(PlaybackService.RADIO); }); controls.addView(radioPlay);
        Button skip = Ui.button(this, "换一首  ›", false, v -> command(PlaybackService.RADIO)); LinearLayout.LayoutParams skipParams = new LinearLayout.LayoutParams(-2, -2); skipParams.leftMargin = Ui.dp(this, 12); controls.addView(skip, skipParams); Ui.padding(controls, 20, 8);
        radioHint = Ui.text(this, "点击开始，从服务器为你挑选一首歌。", 12, Ui.MUTED); radioHint.setGravity(Gravity.CENTER); radioHint.setLineSpacing(Ui.dp(this, 4), 1); radioHint.setMaxLines(3); Ui.padding(radioHint, 24, 6);
        scroll.addView(page); outer.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1)); outer.addView(controls); outer.addView(radioHint); outer.addView(Ui.space(this, 8)); return outer;
    }
    private View playlistPage() { playlistsBody = Ui.column(this); Ui.padding(playlistsBody, 20, 12); return playlistsBody; }
    private void rebuildPlaylists() { pages[PLAYLISTS] = null; playlistAdapter = null; selectTab(PLAYLISTS, false); }
    private void renderPlaylists() {
        if (playlistsBody == null) return; playlistsBody.removeAllViews();
        Repository.Playlist selected = onlinePlaylistSelected || playlistId == null ? null : repo.playlist(playlistId);
        OnlinePlaylist cloud = onlinePlaylistSelected ? repo.onlinePlaylist(playlistId) : null;
        if (selected == null && cloud == null) {
            onlinePlaylistSelected = false;
            playlistId = null; LinearLayout heading = Ui.row(this); TextView title = Ui.text(this, "我的歌单", 26, Ui.TEXT); title.setTypeface(null, Typeface.BOLD); heading.addView(title, Ui.weight());
            heading.addView(Ui.icon(this, R.drawable.ic_plus, "新建歌单", v -> editPlaylist(null, null))); playlistsBody.addView(heading);
            playlistsBody.addView(Ui.space(this, 8)); playlistsBody.addView(Ui.text(this, "把喜欢的声音，放在一起。", 12, Ui.MUTED)); playlistsBody.addView(Ui.space(this, 20));
            ScrollView scroll = new ScrollView(this); LinearLayout lists = Ui.column(this);
            TextView onlineHeading = Ui.text(this, "在线歌单", 17, Ui.ACCENT); lists.addView(onlineHeading); lists.addView(Ui.space(this, 10));
            for (OnlinePlaylist online : repo.onlinePlaylists()) {
                Button card = Ui.button(this, online.name + "  ·  " + online.trackIds.size() + " 首", false, v -> { playlistId = online.id; onlinePlaylistSelected = true; rebuildPlaylists(); });
                card.setAllCaps(false); lists.addView(card, new LinearLayout.LayoutParams(-1, -2)); lists.addView(Ui.space(this, 8));
            }
            if (repo.onlinePlaylists().isEmpty()) lists.addView(Ui.text(this, repo.online ? "在服务端管理页面创建在线歌单，刷新后显示在这里。" : "连接服务器后加载在线歌单。", 12, Ui.MUTED));
            if (!repo.playlistStatus.isEmpty()) lists.addView(Ui.text(this, repo.playlistStatus, 11, Ui.MUTED));
            lists.addView(Ui.space(this, 20)); lists.addView(Ui.text(this, "本地歌单", 17, Ui.ACCENT)); lists.addView(Ui.space(this, 10));
            if (repo.playlists.isEmpty()) { TextView empty = Ui.text(this, "还没有歌单\n点击右上角 ＋ 创建第一张歌单", 15, Ui.MUTED); empty.setGravity(Gravity.CENTER); Ui.padding(empty, 12, 50); lists.addView(empty); }
            for (Repository.Playlist playlist : repo.playlists) {
                LinearLayout card = Ui.row(this); Ui.padding(card, 16, 13); card.setBackground(Ui.round(this, Ui.PANEL, 16));
                ImageView icon = new ImageView(this); icon.setImageResource(R.drawable.ic_playlist); icon.setImageTintList(ColorStateList.valueOf(Ui.ACCENT)); card.addView(icon, new LinearLayout.LayoutParams(Ui.dp(this, 30), Ui.dp(this, 30)));
                LinearLayout copy = Ui.column(this); Ui.padding(copy, 14, 2); copy.addView(Ui.text(this, playlist.name, 16, Ui.TEXT)); copy.addView(Ui.text(this, playlist.keys.size() + " 首歌曲", 11, Ui.MUTED)); card.addView(copy, Ui.weight());
                card.addView(Ui.icon(this, R.drawable.ic_more, "管理歌单 " + playlist.name, v -> {
                    PopupMenu menu = new PopupMenu(this, v); menu.getMenu().add("一键上传云端"); menu.getMenu().add("重命名"); menu.getMenu().add("删除歌单");
                    menu.setOnMenuItemClickListener(item -> { if (item.getTitle().equals("一键上传云端")) repo.uploadToCloud(null, playlist.id); else if (item.getTitle().equals("重命名")) editPlaylist(playlist.id, null); else new AlertDialog.Builder(this).setTitle("删除「" + playlist.name + "」？").setMessage("歌曲与离线缓存会保留。").setNegativeButton("取消", null).setPositiveButton("删除", (d, w) -> repo.deletePlaylist(playlist.id)).show(); return true; }); menu.show();
                }));
                card.setOnClickListener(v -> { playlistId = playlist.id; onlinePlaylistSelected = false; rebuildPlaylists(); }); lists.addView(card, new LinearLayout.LayoutParams(-1, -2)); lists.addView(Ui.space(this, 10));
            }
            lists.addView(Ui.space(this, 12)); lists.addView(Ui.text(this, "歌单与喜欢保存在这台设备，重启后仍会保留。", 11, Ui.MUTED)); scroll.addView(lists); playlistsBody.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        } else {
            Button back = Ui.button(this, "‹  返回歌单", false, v -> { playlistId = null; onlinePlaylistSelected = false; rebuildPlaylists(); }); playlistsBody.addView(back); playlistsBody.addView(Ui.space(this, 15));
            playlistTitle = Ui.text(this, cloud != null ? cloud.name : selected.name, 27, Ui.TEXT); playlistTitle.setTypeface(null, Typeface.BOLD); playlistsBody.addView(playlistTitle); playlistsBody.addView(Ui.space(this, 14));
            List<Song> values = new ArrayList<>();
            if (cloud != null) values.addAll(repo.onlinePlaylistSongs(cloud.id));
            else { Map<String, Song> available = new HashMap<>(); for (Song song : repo.available()) available.put(song.key, song); for (String key : selected.keys) if (available.containsKey(key)) values.add(available.get(key)); }
            int total = cloud != null ? cloud.trackIds.size() : selected.keys.size();
            if (selected != null) playlistsBody.addView(Ui.button(this, "↑ 一键上传云端", false, v -> repo.uploadToCloud(null, selected.id)));
            playlistSummary = Ui.text(this, (cloud != null ? "在线歌单 · " : "") + values.size() + " 首可播放 · 共 " + total + " 首", 12, Ui.MUTED); playlistsBody.addView(playlistSummary); playlistsBody.addView(Ui.space(this, 14));
            playlistsBody.addView(Ui.button(this, "▶ 播放歌单", true, v -> {
                if (playlistAdapter != null && !playlistAdapter.values.isEmpty()) {
                    if (cloud != null && repo.mode == Core.Mode.SHUFFLE) { repo.mode = Core.Mode.LOOP; repo.save(); }
                    play(playlistAdapter.values.get(0), playlistAdapter.values);
                }
            })); playlistsBody.addView(Ui.space(this, 12));
            ListView list = list(); playlistAdapter = new SongAdapter(cloud != null ? null : selected.id); playlistAdapter.replace(values); list.setAdapter(playlistAdapter); playlistsBody.addView(list, new LinearLayout.LayoutParams(-1, 0, 1));
            if (values.isEmpty()) playlistsBody.addView(Ui.text(this, total == 0 ? (cloud != null ? "在服务端管理页中向这张歌单添加歌曲。" : "在歌曲的 ⋮ 菜单中加入这张歌单。") : "离线时仅显示已缓存的歌曲，连接后恢复。", 12, Ui.MUTED));
        }
    }

    private View settingsPage() {
        ScrollView scroll = new ScrollView(this); LinearLayout page = Ui.column(this); Ui.padding(page, 22, 16);
        TextView title = Ui.text(this, "连接你的音乐", 27, Ui.TEXT); title.setTypeface(null, Typeface.BOLD); page.addView(title); page.addView(Ui.space(this, 9));
        TextView intro = Ui.text(this, "使用现有访问令牌，连接声屿在线曲库。", 12, Ui.MUTED); page.addView(intro); page.addView(Ui.space(this, 23));
        onlineSwitch = new Switch(this); onlineSwitch.setText("启用在线模式"); onlineSwitch.setTextColor(Ui.TEXT); onlineSwitch.setTextSize(15); onlineSwitch.setChecked(repo.credentials.enabled()); page.addView(onlineSwitch); page.addView(Ui.space(this, 20));
        page.addView(Ui.text(this, "服务器地址", 12, Ui.MUTED)); page.addView(Ui.space(this, 8)); serverEdit = Ui.input(this, "https://121.40.254.112"); serverEdit.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI); serverEdit.setText(repo.credentials.server()); page.addView(serverEdit); page.addView(Ui.space(this, 17));
        page.addView(Ui.text(this, "访问令牌", 12, Ui.MUTED)); page.addView(Ui.space(this, 8)); tokenEdit = Ui.input(this, "输入令牌；留空保留已保存的令牌"); tokenEdit.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD); tokenEdit.setSaveEnabled(false); page.addView(tokenEdit); page.addView(Ui.space(this, 6));
        clearToken = new CheckBox(this); clearToken.setText("清除该服务器已保存的令牌"); clearToken.setTextColor(Ui.MUTED); clearToken.setTextSize(12); clearToken.setOnCheckedChangeListener((button, checked) -> tokenEdit.setEnabled(!checked)); page.addView(clearToken); page.addView(Ui.space(this, 12));
        page.addView(Ui.button(this, "保存并连接", true, v -> {
            try {
                repo.saveSettings(serverEdit.getText().toString(), onlineSwitch.isChecked(), tokenEdit.getText().toString(), clearToken.isChecked());
                tokenEdit.setText(""); clearToken.setChecked(false); serverEdit.setText(repo.credentials.server());
                ((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(tokenEdit.getWindowToken(), 0);
                root.requestFocus(); toast("连接设置已保存");
            } catch (Exception error) { toast(error instanceof IllegalArgumentException ? error.getMessage() : "无法保存令牌，请检查系统安全存储后重试"); }
        }));
        settingsStatus = Ui.text(this, repo.status, 12, Ui.MUTED); page.addView(Ui.space(this, 12)); page.addView(settingsStatus); page.addView(Ui.space(this, 20));
        TextView privacy = Ui.text(this, "令牌通过 Android Keystore 加密保存在本机。连接失败时使用本地与缓存音乐，在线曲库每 30 秒自动刷新。", 11, Ui.MUTED); privacy.setLineSpacing(Ui.dp(this, 5), 1); page.addView(privacy); page.addView(Ui.space(this, 23));
        page.addView(Ui.button(this, "打开服务端歌曲管理  ↗", false, v -> {
            try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(Core.server(serverEdit.getText().toString()) + "/music.html"))); }
            catch (Exception error) { toast("请检查服务器地址及浏览器设置"); }
        })); page.addView(Ui.space(this, 10));
        page.addView(Ui.button(this, "导入本地音乐", false, v -> {
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("audio/*").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
            try { startActivityForResult(intent, IMPORT_AUDIO); } catch (ActivityNotFoundException error) { toast("设备未提供文件选择器"); }
        })); page.addView(Ui.space(this, 25));
        page.addView(Ui.text(this, "离线存储", 17, Ui.TEXT)); page.addView(Ui.space(this, 8)); cacheSize = Ui.text(this, "", 12, Ui.MUTED); page.addView(cacheSize); page.addView(Ui.space(this, 12));
        page.addView(Ui.button(this, "清理服务器歌曲缓存", false, v -> new AlertDialog.Builder(this).setTitle("清理离线缓存？")
                .setMessage("将停止当前播放，并清理服务器歌曲的离线副本。收藏、歌单和导入的本地音乐会保留。")
                .setNegativeButton("取消", null).setPositiveButton("清理", (d, w) -> { if (service != null) service.clearDownloadedAudio(); else repo.clearDownloaded(); Ui.covers.evictAll(); toast("正在清理离线缓存"); }).show()));
        page.addView(Ui.space(this, 24)); page.addView(Ui.text(this, "声屿 Android 1.1.1\n每一首喜欢，都有一座岛。", 11, Ui.MUTED)); page.addView(Ui.space(this, 20)); scroll.addView(page); return scroll;
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == IMPORT_AUDIO && result == RESULT_OK && data != null) {
            ArrayList<Uri> uris = new ArrayList<>();
            if (data.getClipData() != null) for (int i = 0; i < data.getClipData().getItemCount(); i++) uris.add(data.getClipData().getItemAt(i).getUri());
            else if (data.getData() != null) uris.add(data.getData());
            repo.importAudio(uris); selectTab(LIBRARY, false);
        }
    }
    private void renderCatalog() {
        connectionStatus.setText(repo.refreshing ? getString(R.string.connection_refreshing, repo.status) : repo.status); connectionStatus.setTextColor(repo.online ? Ui.ACCENT : Ui.MUTED);
        if (tab == LIBRARY) renderSongs();
        else if (tab == PLAYLISTS) {
            Repository.Playlist selected = playlistId == null ? null : repo.playlist(playlistId);
            if (selected != null && playlistAdapter != null) {
                List<Song> values = new ArrayList<>(); Map<String, Song> available = new HashMap<>(); for (Song song : repo.available()) available.put(song.key, song);
                for (String key : selected.keys) if (available.containsKey(key)) values.add(available.get(key));
                playlistAdapter.replace(values); playlistTitle.setText(selected.name); playlistSummary.setText(getString(R.string.playlist_summary, values.size(), selected.keys.size()));
            } else renderPlaylists();
        }
        if (settingsStatus != null) settingsStatus.setText(repo.status);
        if (cacheSize != null) cacheSize.setText(String.format(Locale.CHINA, "在线歌曲缓存 %.1f MB · 本地音乐会单独保留", repo.cachedBytes() / 1048576.0));
    }
    @Override public void changed(boolean settingsChanged) { renderCatalog(); renderPlayback(false); }
    @Override public void playbackChanged(boolean songChanged) { renderPlayback(songChanged); }
    private void command(String action) { dispatch(new Intent(this, PlaybackService.class).setAction(action)); }
    private void dispatch(Intent intent) {
        String action = intent.getAction();
        boolean foreground = !Arrays.asList(PlaybackService.STOP, PlaybackService.SEEK, PlaybackService.ENQUEUE).contains(action);
        if (foreground) {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED && !getPreferences(0).getBoolean("notificationAsked", false)) {
                getPreferences(0).edit().putBoolean("notificationAsked", true).apply(); requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 71);
            }
            startForegroundService(intent);
        } else startService(intent);
    }
    private void play(Song song, List<Song> source) {
        ArrayList<String> queue = new ArrayList<>(); for (Song item : source) queue.add(item.key);
        dispatch(new Intent(this, PlaybackService.class).setAction(PlaybackService.PLAY).putExtra("key", song.key).putStringArrayListExtra("queue", queue));
    }
    private void buildMini() {
        LinearLayout frame = Ui.column(this); Ui.padding(frame, 12, 0); mini = Ui.column(this); mini.setBackground(Ui.round(this, Ui.PANEL, 16));
        LinearLayout row = Ui.row(this); Ui.padding(row, 10, 7); miniArt = new Ui.Art(this, 42); row.addView(miniArt);
        LinearLayout copy = Ui.column(this); Ui.padding(copy, 11, 0); miniTitle = Ui.text(this, "", 13, Ui.TEXT); miniTitle.setSingleLine(true); miniTitle.setEllipsize(TextUtils.TruncateAt.END); miniArtist = Ui.text(this, "", 10, Ui.MUTED); miniArtist.setSingleLine(true); miniArtist.setEllipsize(TextUtils.TruncateAt.END); copy.addView(miniTitle); copy.addView(Ui.space(this, 5)); copy.addView(miniArtist); row.addView(copy, Ui.weight()); copy.setOnClickListener(v -> showFullPlayer()); miniArt.setOnClickListener(v -> showFullPlayer());
        miniPlay = Ui.icon(this, R.drawable.ic_play, "播放 / 暂停", v -> command(PlaybackService.TOGGLE)); miniPlay.setImageTintList(ColorStateList.valueOf(Ui.ACCENT)); row.addView(miniPlay); row.addView(Ui.icon(this, R.drawable.ic_next, "下一首", v -> command(PlaybackService.NEXT))); mini.addView(row);
        miniProgress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal); miniProgress.setProgressTintList(ColorStateList.valueOf(Ui.ACCENT)); miniProgress.setProgressBackgroundTintList(ColorStateList.valueOf(Ui.PANEL)); miniProgress.setMax(1000); mini.addView(miniProgress, new LinearLayout.LayoutParams(-1, Ui.dp(this, 2))); frame.addView(mini); root.addView(frame); mini.setVisibility(View.GONE);
    }
    private void renderPlayback(boolean songChanged) {
        Song song = service == null ? null : service.current(); boolean hasCurrent = song != null || service != null && service.loading;
        mini.setVisibility(hasCurrent ? View.VISIBLE : View.GONE);
        if (service == null) return;
        if (hasCurrent) {
            miniTitle.setText(song == null ? "正在为你寻找下一首…" : song.title); miniArtist.setText(service.loading ? service.message : song == null ? "我的电台" : song.artist);
            miniArt.bind(repo, song, Ui.dp(this, 60)); miniPlay.setImageResource(service.playing || service.loading ? R.drawable.ic_pause : R.drawable.ic_play);
            miniPlay.setContentDescription(service.playing || service.loading ? "暂停 / 取消加载" : "继续播放");
            miniProgress.setProgress(service.duration <= 0 ? 0 : (int)(service.position() * 1000 / service.duration));
        }
        if (tab == RADIO && radioArt != null) {
            Song radioSong = service.radio ? song : null; radioArt.bind(repo, radioSong, Ui.dp(this, 240));
            radioTitle.setText(radioSong == null ? "下一首，刚好喜欢" : radioSong.title); radioArtist.setText(radioSong == null ? "" : radioSong.artist); radioAlbum.setText(radioSong == null ? "" : radioSong.album);
            radioBadge.setText(repo.online ? "在线电台" : "离线电台");
            radioPlay.setText(!service.radio ? "开始收听" : service.loading ? "取消加载" : service.playing ? "暂 停" : "继续收听");
            radioHint.setText(service.radio || song == null ? service.message : "点击开始，从服务器为你挑选一首歌。");
            radioHeart.setImageResource(radioSong != null && radioSong.favorite ? R.drawable.ic_heart_fill : R.drawable.ic_heart); radioHeart.setImageTintList(ColorStateList.valueOf(radioSong != null && radioSong.favorite ? Ui.ACCENT : Ui.MUTED)); radioHeart.setEnabled(radioSong != null);
        }
        if (fullPlayer != null && fullPlayer.isShowing()) {
            fullArt.bind(repo, song, Ui.dp(this, 300)); fullTitle.setText(song == null ? "音乐，等待响起" : song.title); fullArtist.setText(song == null ? "" : song.artist + " · " + song.album); fullStatus.setText(service.message);
            fullPlay.setImageResource(service.playing || service.loading ? R.drawable.ic_pause : R.drawable.ic_play); fullHeart.setImageResource(song != null && song.favorite ? R.drawable.ic_heart_fill : R.drawable.ic_heart); fullHeart.setImageTintList(ColorStateList.valueOf(song != null && song.favorite ? Ui.ACCENT : Ui.MUTED));
            if (!seeking) { fullSeek.setMax((int)Math.max(1, service.duration / 1000)); fullSeek.setProgress((int)(service.position() / 1000)); fullElapsed.setText(Core.time(service.position())); }
            fullDuration.setText(Core.time(service.duration)); fullSeek.setEnabled(!service.loading && song != null);
            modeButton.setText(service.radio ? "电台 · 自动续播" : repo.mode.label); modeButton.setEnabled(!service.radio);
        }
        if (songChanged) { if (libraryAdapter != null) libraryAdapter.notifyDataSetChanged(); if (playlistAdapter != null) playlistAdapter.notifyDataSetChanged(); }
    }
    private void showFullPlayer() {
        if (service == null || fullPlayer != null && fullPlayer.isShowing()) return;
        Dialog dialog = new Dialog(this, android.R.style.Theme_Material_NoActionBar); fullPlayer = dialog;
        LinearLayout page = Ui.column(this); page.setBackgroundColor(Ui.BG); applyInsets(page);
        LinearLayout bar = Ui.row(this); Ui.padding(bar, 20, 12); TextView label = Ui.text(this, "NOW PLAYING", 11, Ui.ACCENT); label.setLetterSpacing(.15f); bar.addView(label, Ui.weight()); bar.addView(Ui.icon(this, R.drawable.ic_close, "关闭正在播放", v -> dialog.dismiss())); page.addView(bar);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); LinearLayout art = Ui.column(this); art.setGravity(Gravity.CENTER); Ui.padding(art, 28, 16);
        fullArt = new Ui.Art(this, 238); art.addView(fullArt); art.addView(Ui.space(this, 28)); fullTitle = Ui.text(this, "", 25, Ui.TEXT); fullTitle.setGravity(Gravity.CENTER); fullTitle.setTypeface(null, Typeface.BOLD); art.addView(fullTitle); art.addView(Ui.space(this, 12)); fullArtist = Ui.text(this, "", 13, Ui.MUTED); fullArtist.setGravity(Gravity.CENTER); art.addView(fullArtist); art.addView(Ui.space(this, 17)); fullStatus = Ui.text(this, "", 11, Ui.MUTED); fullStatus.setGravity(Gravity.CENTER); art.addView(fullStatus); scroll.addView(art); page.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        LinearLayout progress = Ui.column(this); Ui.padding(progress, 26, 6); fullSeek = new SeekBar(this); fullSeek.setProgressTintList(ColorStateList.valueOf(Ui.ACCENT)); fullSeek.setThumbTintList(ColorStateList.valueOf(Ui.ACCENT)); progress.addView(fullSeek); LinearLayout times = Ui.row(this); fullElapsed = Ui.text(this, "0:00", 11, Ui.MUTED); times.addView(fullElapsed, Ui.weight()); fullDuration = Ui.text(this, "0:00", 11, Ui.MUTED); times.addView(fullDuration); progress.addView(times); page.addView(progress);
        fullSeek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar seekBar, int value, boolean user) { if (user) fullElapsed.setText(Core.time(value * 1000L)); }
            @Override public void onStartTrackingTouch(SeekBar seekBar) { seeking = true; }
            @Override public void onStopTrackingTouch(SeekBar seekBar) { seeking = false; dispatch(new Intent(MainActivity.this, PlaybackService.class).setAction(PlaybackService.SEEK).putExtra("position", seekBar.getProgress() * 1000L)); }
        });
        LinearLayout controls = Ui.row(this); controls.setGravity(Gravity.CENTER); Ui.padding(controls, 10, 17);
        controls.addView(Ui.icon(this, R.drawable.ic_previous, "上一首", v -> command(PlaybackService.PREVIOUS)));
        fullPlay = Ui.icon(this, R.drawable.ic_play, "播放 / 暂停", v -> command(PlaybackService.TOGGLE)); fullPlay.setImageTintList(ColorStateList.valueOf(Ui.BG)); fullPlay.setBackground(Ui.round(this, Ui.ACCENT, 32)); LinearLayout.LayoutParams playParams = new LinearLayout.LayoutParams(Ui.dp(this, 66), Ui.dp(this, 66)); playParams.setMargins(Ui.dp(this, 26), 0, Ui.dp(this, 26), 0); controls.addView(fullPlay, playParams);
        controls.addView(Ui.icon(this, R.drawable.ic_next, "下一首", v -> command(PlaybackService.NEXT))); page.addView(controls);
        LinearLayout extras = Ui.row(this); extras.setGravity(Gravity.CENTER); Ui.padding(extras, 20, 12); fullHeart = Ui.icon(this, R.drawable.ic_heart, "喜欢当前歌曲", v -> { if (service.current() != null) repo.toggleFavorite(service.currentKey); }); extras.addView(fullHeart);
        modeButton = Ui.button(this, repo.mode.label, false, v -> {
            String[] modes = new String[Core.Mode.values().length]; for (int i = 0; i < modes.length; i++) modes[i] = Core.Mode.values()[i].label;
            new AlertDialog.Builder(this).setTitle("播放顺序").setSingleChoiceItems(modes, repo.mode.ordinal(), (d, which) -> { repo.mode = Core.Mode.values()[which]; repo.save(); renderPlayback(false); d.dismiss(); }).show();
        }); extras.addView(modeButton);
        extras.addView(Ui.icon(this, R.drawable.ic_add_playlist, "加入歌单", v -> { if (service.current() != null) addToPlaylist(service.current()); }));
        extras.addView(Ui.icon(this, R.drawable.ic_stop, "停止播放", v -> command(PlaybackService.STOP))); page.addView(extras);
        dialog.setContentView(page); dialog.setOnDismissListener(d -> { fullPlayer = null; seeking = false; }); dialog.show(); dialog.getWindow().setLayout(-1, -1); renderPlayback(false);
    }
    private void editPlaylist(String id, Song adding) {
        Repository.Playlist list = id == null ? null : repo.playlist(id);
        EditText input = Ui.input(this, "给歌单起个名字"); input.setFilters(new InputFilter[]{new InputFilter.LengthFilter(80)}); if (list != null) input.setText(list.name);
        LinearLayout field = Ui.column(this); Ui.padding(field, 22, 10); field.addView(input);
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle(id == null ? "新建歌单" : "重命名歌单").setView(field).setNegativeButton("取消", null).setPositiveButton("保存", null).create();
        dialog.setOnShowListener(d -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            try {
                if (id == null) { Repository.Playlist created = repo.createPlaylist(input.getText().toString()); if (adding != null) repo.addToPlaylist(adding.key, created.id); }
                else repo.renamePlaylist(id, input.getText().toString()); dialog.dismiss();
            } catch (IllegalArgumentException error) { input.setError(error.getMessage()); }
        })); dialog.show();
    }
    private void addToPlaylist(Song song) {
        ArrayList<Repository.Playlist> snapshot = new ArrayList<>(repo.playlists); String[] names = new String[snapshot.size() + 1];
        for (int i = 0; i < snapshot.size(); i++) names[i] = snapshot.get(i).name + (snapshot.get(i).keys.contains(song.key) ? "  ✓" : ""); names[names.length - 1] = "＋ 新建歌单并添加";
        new AlertDialog.Builder(this).setTitle("加入歌单").setItems(names, (d, which) -> { if (which == snapshot.size()) editPlaylist(null, song); else { repo.addToPlaylist(song.key, snapshot.get(which).id); toast("已加入「" + snapshot.get(which).name + "」"); } }).show();
    }
    private void confirmDeleteSong(Song song) {
        if (repo.storageBusy) { toast("请等待当前上传或清理完成"); return; }
        AlertDialog.Builder dialog = new AlertDialog.Builder(this).setTitle("删除《" + song.title + "》？")
                .setMessage("删除云端副本会移出所有在线歌单，并清理本机缓存，其他设备重新连接后同步。本地歌曲删除的是应用内导入的副本，原始文件会保留。")
                .setNegativeButton("取消", null);
        if (song.local()) dialog.setNeutralButton("删除本地副本", (d, w) -> repo.deleteSong(song, false));
        if (song.hasCloud()) dialog.setPositiveButton("删除云端及缓存", (d, w) -> repo.deleteSong(song, true));
        dialog.show();
    }
    private void songMenu(View anchor, Song song, String playlist) {
        PopupMenu menu = new PopupMenu(this, anchor); menu.getMenu().add(song.favorite ? "取消喜欢" : "喜欢这首歌"); menu.getMenu().add("加入歌单"); menu.getMenu().add("下一首播放");
        if (song.local()) menu.getMenu().add("一键上传云端");
        menu.getMenu().add("删除歌曲…");
        if (playlist != null) menu.getMenu().add("从歌单移除");
        menu.setOnMenuItemClickListener(item -> {
            String title = item.getTitle().toString();
            if (title.equals("删除歌曲…")) confirmDeleteSong(song);
            else if (title.equals("一键上传云端")) repo.uploadToCloud(song.key, null);
            else if (title.equals("加入歌单")) addToPlaylist(song);
            else if (title.equals("下一首播放")) { dispatch(new Intent(this, PlaybackService.class).setAction(PlaybackService.ENQUEUE).putExtra("key", song.key)); toast("已安排下一首播放"); }
            else if (title.equals("从歌单移除")) repo.removeFromPlaylist(song.key, playlist);
            else repo.toggleFavorite(song.key);
            return true;
        }); menu.show();
    }
    private void toast(String value) { Toast.makeText(this, value, Toast.LENGTH_LONG).show(); }
    private final class SongAdapter extends BaseAdapter {
        private final ArrayList<Song> values = new ArrayList<>();
        private final String playlist;
        SongAdapter(String playlist) { this.playlist = playlist; }
        void replace(List<Song> values) { this.values.clear(); this.values.addAll(values); notifyDataSetChanged(); }
        @Override public int getCount() { return values.size(); }
        @Override public Song getItem(int position) { return values.get(position); }
        @Override public long getItemId(int position) { return values.get(position).key.hashCode(); }
        @Override public View getView(int position, View convert, ViewGroup parent) {
            Row holder;
            if (convert == null) { holder = new Row(); convert = holder.root; convert.setTag(holder); }
            else holder = (Row) convert.getTag();
            Song song = values.get(position); holder.art.bind(repo, song, Ui.dp(MainActivity.this, 70)); holder.title.setText(song.title);
            String description = song.cached ? getString(R.string.song_cached, song.artist) : song.artist;
            holder.subtitle.setText(song.plays > 0 ? getString(R.string.song_play_count, description, song.plays) : description);
            boolean current = service != null && song.key.equals(service.currentKey); holder.title.setTextColor(current ? Ui.ACCENT : Ui.TEXT);
            holder.root.setBackground(Ui.round(MainActivity.this, current ? 0xff1c261c : Ui.BG, 12));
            holder.heart.setImageResource(song.favorite ? R.drawable.ic_heart_fill : R.drawable.ic_heart); holder.heart.setImageTintList(ColorStateList.valueOf(song.favorite ? Ui.ACCENT : Ui.MUTED));
            holder.sources.removeAllViews();
            if (song.cached) { ImageView local = new ImageView(MainActivity.this); local.setImageResource(R.drawable.ic_local); local.setImageTintList(ColorStateList.valueOf(Ui.MUTED)); holder.sources.addView(local, new LinearLayout.LayoutParams(Ui.dp(MainActivity.this, 15), Ui.dp(MainActivity.this, 15))); }
            if (song.hasCloud()) { ImageView cloudIcon = new ImageView(MainActivity.this); cloudIcon.setImageResource(R.drawable.ic_cloud); cloudIcon.setImageTintList(ColorStateList.valueOf(Ui.ACCENT)); holder.sources.addView(cloudIcon, new LinearLayout.LayoutParams(Ui.dp(MainActivity.this, 18), Ui.dp(MainActivity.this, 15))); }
            holder.sources.setContentDescription(song.cached && song.hasCloud() ? "本地与云端都有" : song.hasCloud() ? "云端歌曲" : "本地歌曲");
            holder.delete.setEnabled(!repo.storageBusy); holder.delete.setOnClickListener(v -> confirmDeleteSong(song));
            holder.heart.setContentDescription((song.favorite ? "取消喜欢 " : "喜欢 ") + song.title); holder.heart.setOnClickListener(v -> repo.toggleFavorite(song.key)); holder.more.setOnClickListener(v -> songMenu(v, song, playlist));
            holder.root.setOnClickListener(v -> play(song, values)); return convert;
        }
        private final class Row {
            final LinearLayout root = Ui.row(MainActivity.this);
            final LinearLayout sources = Ui.row(MainActivity.this);
            final ImageButton delete = Ui.icon(MainActivity.this, R.drawable.ic_delete, "删除歌曲", null);
            final Ui.Art art = new Ui.Art(MainActivity.this, 48);
            final TextView title = Ui.text(MainActivity.this, "", 15, Ui.TEXT), subtitle = Ui.text(MainActivity.this, "", 11, Ui.MUTED);
            final ImageButton heart = Ui.icon(MainActivity.this, R.drawable.ic_heart, "喜欢", null), more = Ui.icon(MainActivity.this, R.drawable.ic_more, "歌曲操作", null);
            Row() {
                Ui.padding(root, 5, 9); root.addView(art); LinearLayout copy = Ui.column(MainActivity.this); Ui.padding(copy, 11, 0);
                title.setSingleLine(true); title.setEllipsize(TextUtils.TruncateAt.END); subtitle.setSingleLine(true); subtitle.setEllipsize(TextUtils.TruncateAt.END); copy.addView(title); copy.addView(Ui.space(MainActivity.this, 6)); copy.addView(subtitle); copy.addView(sources); root.addView(copy, Ui.weight()); root.addView(heart); root.addView(delete); root.addView(more);
            }
        }
    }
}
