# Sonora · 声屿

**English** | [简体中文](README.zh-CN.md)

A native macOS music player built with SwiftUI, AppKit, and AVFoundation. Sonora brings your local music, playlists, and listening statistics together in a dark interface with soft green accents. It also connects to a compatible music server and caches downloaded tracks for offline listening.

No third-party dependencies. The application interface is currently in Simplified Chinese.

An Android client is available in [android/](android/README.md), with online/offline playback, radio, favorites, playlists, and background media controls. Build its installable APK with `bash Scripts/build-android.sh`.

## Features

- **Local library:** import files or folders recursively, drag music into the window, or use Finder’s **Open With** menu. Duplicate file paths are skipped.
- **Playback controls:** play, pause, stop, seek, adjust volume, and mute. Choose sequential playback, repeat all, repeat one, or shuffle.
- **Mini player:** a movable, fixed-size 380 × 124-point player with artwork, track information, playback controls, a progress bar, and a playback-mode menu. Returning to the full player restores its previous window size and position.
- **Library organization:** browse all music, the 50 most recently added tracks, favorites, and custom playlists. Create, rename, and delete playlists, or add tracks using the “＋” menu.
- **Artists and statistics:** browse artist pages with track counts and play counts. Search tracks by title, artist, album, or filename; sort tracks by date added, title, artist, or play count, and artists by name, play count, or track count.
- **Playback queue:** view upcoming tracks, play a track next, remove queue entries, or clear upcoming tracks.
- **Track information:** read embedded titles, artists, albums, artwork, and duration. Filenames are used when title tags are missing; tracks without artwork use a plain dark placeholder.
- **Find the current track:** click **定位当前**, click the artwork or track information in the playback bar, or press `⌘J` to reveal and highlight the playing track.
- **Cloud uploads and source badges:** upload an individual local song from its menu or a whole local playlist from its detail page. Identical audio is reused, playlist order is retained, and uploaded originals keep their identity. Disk and cloud icons show local and cloud copies together.
- **Deletion and cache cleanup:** each song has a confirmed delete action for its cloud copy or local original. Mac originals move to Trash; removing only a library entry remains available. Clear audio and artwork caches in server settings while retaining originals, favorites, playlists and credentials. Successfully refreshed server catalogs remove deleted cloud songs and caches; offline devices reconcile when they reconnect.
- **Online and offline listening:** browse server tracks, download on first playback, and keep listening to local and cached music when the server is unavailable.
- **My Radio:** open **我的电台** in the sidebar to play random server songs. Skip with **换一首** or the player’s Next button; finishing a song advances automatically. Offline radio selects local or cached songs.
- **Look-ahead caching:** while playing, cache the next three songs and replenish after each skip. Regular playback follows the queue; radio prepares random upcoming selections. Local and cached files are reused. Pausing, stopping, or disconnecting cancels prefetch; background failures leave the current song playing.
- **Native integration:** macOS Now Playing information and media commands, keyboard shortcuts, and saved library and playback state. Playback stays paused when the app is reopened.

Supported file extensions: **MP3, M4A, AAC, WAV, AIF, AIFF, CAF, and FLAC**. Actual codec support depends on macOS decoding capabilities.

## Requirements

- macOS **14.0 or later**.
- Packaged builds described here target **Apple Silicon**. Source builds can target `arm64` or `x86_64`; Intel builds have not been verified on a physical Intel Mac.
- To build from source: Xcode or Apple Command Line Tools with **Swift 6.0 or later**.

## Installation

If you have a packaged DMG, open it and drag **声屿.app** into **Applications**. Quit the previous version before replacing it when upgrading. Your library and playlists are stored separately from the app bundle.

Current builds use ad hoc signing and are not signed with an Apple Developer certificate or notarized. If macOS blocks the app, allow it in **System Settings → Privacy & Security**.

To create an app bundle yourself, follow [Build from source](#build-from-source).

## Getting started

### Local music

1. Click **添加我的音乐** (“Add My Music”) or press `⌘O` to select audio files or folders. You can also drag them into the window.
2. Double-click a track to play it. A single click selects it without automatically scrolling the list.
3. Use the heart to favorite a track and “＋” to add it to a playlist. Right-click a track for more actions, including revealing its file in Finder or removing it from the library.
4. Press `⌥⌘M` to switch between the full player and mini player.

Local music stays at its original location: importing does not copy files, and removing a library entry does not delete the original. The separate local-file delete action moves it to Trash. If you move a music file, remove the unavailable entry and import it again.

Closing the window allows playback to continue in the background. Use `⌘Q` to quit the app.

### Server connection

Online mode is enabled by default with a preconfigured server address. You can change the server or disable online mode for local-only use:

1. Open **服务器连接…** (“Server Connection”) from the application menu, or click the online/offline status in the sidebar.
2. Enter the server’s HTTPS base URL and, if required, its access token. Local development also accepts HTTP on `localhost`, `127.0.0.1`, or `::1`.
3. Click **保存并连接** (“Save and Connect”). Leave the token field empty to retain the token already saved for that server, or select the clear-token option to remove it.

While online mode is enabled, the app refreshes the connection and track list every 30 seconds. Connection failures or expired authentication switch the library to local and already-cached music; errors in an individual feature or song keep the healthy catalog online. Uncached server tracks require a working connection; their first playback waits for the download to complete. Downloads are checked against the server’s file size and SHA-256 digest before being cached.

The **在线歌单** and **我的歌单** sidebar entries open separate playlist collection pages. Select a playlist card for its tracks and use the back link to return. Collection search matches playlist names, and local cards retain create, rename and delete actions.

Create shared online playlists in the music management page, then upload into a playlist or add selected library songs. Select a playlist under **在线歌单** in the sidebar and double-click a song or use **播放全部** to play it in server order. Reorder tracks by dragging within a playlist in the management page, or use its up/down controls; changes save immediately. After refreshing the client, start the playlist again to build a queue in the saved order. Library sort settings do not override online playlist order. Lists refresh every 30 seconds and remain visible offline with their cached songs. Shared server playlists remain separate from device-local playlists.

Access tokens are stored in macOS Keychain, separately for each server. The **打开歌曲管理** (“Open Music Management”) button opens the server’s `/music.html` page in your browser.

A compatible server is required; its backend is not included in this repository. The client expects:

| Endpoint | Purpose |
| --- | --- |
| `GET /api/music/playlists` | Return playlists with `id`, `name` and an ordered UUID array `trackIds`. |
| `POST /api/music/tracks?reuseExisting=true` | Upload multipart audio, reusing identical files. |
| `DELETE /api/music/tracks/{id}` | Delete audio and all online playlist references. |
| `POST /api/music/playlists` | Create with an optional stable local playlist UUID. |
| `POST /api/music/playlists/{id}/tracks` | Append ordered batches of songs. |
| `PUT /api/music/playlists/{id}/order` | Save order with an expected previous order. |
| `GET /api/music/tracks` | Return a JSON array of track metadata. |
| `GET /api/music/tracks/{id}/audio` | Download a track’s audio file. |
| `GET /api/music/tracks/radio?exclude=<UUID>` | Pick one playable server song, avoiding the previous song when another is available. Returns 204 for an empty radio. |
| `/music.html` | Browser-based music management page. |

Metadata fields are `id` (UUID), `title`, `artist`, `album`, `duration` (seconds), `extension`, `sha256`, `size` (bytes), and `uploadedAt` (ISO 8601). The client accepts supported lowercase extensions, lowercase SHA-256 digests, and files up to 128 MiB. API requests send `Authorization: Bearer <token>` when a token is configured. See [OnlineLibrary.swift](Sources/Sonora/OnlineLibrary.swift) for the client contract.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘O` | Import audio files or folders |
| `Space` / `⌘P` | Play / pause |
| `←` / `→` | Seek backward / forward 5 seconds |
| `⌘←` / `⌘→` | Previous / next track |
| `⌘F` | Search music |
| `⇧⌘N` | Create a playlist |
| `⌘R` | Cycle playback modes |
| `⌘L` | Show / hide the queue |
| `⌘J` | Reveal the current track |
| `⇧⌘M` | Mute / unmute |
| `⌥⌘M` | Enter / exit mini mode |
| `⌘Q` | Quit |

Space and arrow keys retain their normal editing behavior in text fields.

## Build from source

From the repository root, run:

```sh
bash Scripts/build.sh
```

The script builds a release executable for the current machine’s architecture, generates the app icon, creates `dist/声屿.app`, and applies and verifies an ad hoc signature. It does not launch the application.

It also creates and verifies `dist/声屿-Sonora-<version>.dmg`, keeping only the latest Sonora DMG after successful packaging. To package an already-built app without rebuilding, run `bash Scripts/package-dmg.sh`.

You can also select an architecture explicitly:

```sh
# Apple Silicon
bash Scripts/build.sh arm64

# Intel
bash Scripts/build.sh x86_64
```

Open `Package.swift` in Xcode to work on the project. Full Xcode is not required by the build script, and build caches default to the project’s `.build/` directory.

| Environment variable | Purpose |
| --- | --- |
| `SONORA_BUILD_ROOT` | Override the build and compiler-cache directory used by the scripts. |
| `SONORA_APP_OUTPUT` | Override the app bundle output path used by `Scripts/build.sh`. |
| `SONORA_LIBRARY_PATH` | Override the library JSON path when launching the app for development. Settings and audio cache are placed beside it. |

## Tests and validation

Use the repository’s shell scripts to compile and run the test executables:

| Command | Coverage |
| --- | --- |
| `bash Scripts/test.sh` | Queue rules, playback state, persistence, import and decoding, playlists, current-track navigation, artist statistics, caching, and isolated progress/volume/selection updates. |
| `bash Scripts/test-online.sh` | Mocked authentication, fallback, caching, integrity, and online playlists; a temporary loopback HTTP server checks live download progress, sharing, cancellation, and redirect rejection. No external server, windows, or audio playback. |
| `bash Scripts/test-performance.sh` | Page-data reads for 5,000 simulated tracks; each warmed-up case has a total budget of 100 ms for 8 refreshes. |
| `bash Scripts/test-rendering.sh` | Row values, update boundaries, layout breakpoints, window-constraint logic, and background artwork loading, caching, and cancellation. |
| `bash Scripts/test-mini-window.sh` | Mini/full window constraints and restoration using an offscreen test window. |
| `bash Scripts/test-mini-window-scene.sh` | Production SwiftUI window configuration using a transparent, noninteractive test window. |

The core tests use a generated 12-second silent MP3 fixture and do not play audio, but decoding checks need access to macOS audio services. The performance and rendering-contract checks do not create windows or play audio. Mini-window checks create test windows and require a working macOS window service. Tests use isolated library paths.

Data benchmarks and view-value checks do not measure actual rendering frame rates. Historical verification results and their limits are recorded in [VALIDATION.md](VALIDATION.md) (Chinese).

## Data and playback counts

Default data directory:

```text
~/Library/Application Support/Sonora/
├── library.json          # Track index, playlists, favorites, counts, and playback state
├── online-settings.json  # Server address and online-mode setting
└── online-audio/         # Downloaded server audio
```

The library index stores file paths, metadata, thumbnail artwork, and playback state; it does not embed original audio. Access tokens are kept in Keychain. If the library index cannot be decoded, the app attempts to preserve a recovery copy before allowing a new library to be saved.

A play is counted whenever a track successfully starts a new playback session. Resuming after pause and seeking do not add a play; selecting a track again, playing after stop, and looping do. Libraries created before play counts were introduced start at zero. Artist counts aggregate the tracks currently available in the library, grouping full artist tags while ignoring case and surrounding whitespace. Collaboration tags remain a single artist entry.

Local playback works without a server. Enabling online mode sends catalog and audio requests to the configured server; importing local files does not upload them. The app has no telemetry or online lyrics feature.

## Project layout

```text
Package.swift          Swift package manifest
Sources/Sonora/        SwiftUI views, player model, import, persistence, and online client
Resources/             App bundle metadata
Scripts/               Build, icon generation, and test scripts
Tests/SonoraTests/     Regression checks and the silent audio fixture
VALIDATION.md          Historical validation notes
```

Recent improvements include isolated volume and selection updates, reusable track rows, background artwork decoding, cached page queries, background library saves, artist statistics, and a fixed-size mini player with playback-mode selection.
