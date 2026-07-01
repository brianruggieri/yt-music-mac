# YouTube Music for macOS

A lightweight native macOS wrapper for YouTube Music with system integration.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Native macOS app** — No Electron, just a lean WebKit wrapper
- **Media key support** — Control playback with your keyboard's play/pause, next, and previous keys
- **Now Playing integration** — See track info in Control Center with album artwork
- **Discord Rich Presence** — Show what you're listening to on Discord
- **Spotify import** — Connect a Spotify account to match and import your playlists and liked songs into YouTube Music
- **Frameless design** — Clean, minimal window that blends with YouTube Music's UI
- **Native scrollbars** — macOS-style scrollbars for a consistent look
- **Visualizer** — a third "Visualizer" option on YT Music's Song/Video toggle renders an audio-reactive Butterchurn (MilkDrop) visualization driven by a native Core Audio process tap of the app's own audio; requires macOS 14.4+ (hidden otherwise) and Audio Capture permission (prompted on first use)

## Screenshots

![App](screenshots/youtube-app.png)

| Control Center | Discord Rich Presence |
|:--------------:|:---------------------:|
| ![Control Center](screenshots/control-center.png) | ![Discord](screenshots/discord-status.png) |

## Installation

### Homebrew (Recommended)

```bash
brew tap 0xjemm/youtube-music-macos
brew install --cask youtube-music-macos
xattr -cr /Applications/YouTube\ Music.app
```

### Manual

1. Download the latest release from [Releases](../../releases)
2. Extract and drag to Applications
3. Run `xattr -cr /Applications/YouTube\ Music.app` (required for unnotarized apps)
4. Open and sign in to YouTube Music

### Building from Source

1. Clone the repository
2. Copy `Secrets.example.swift` to `youtube-music-player/Secrets.swift` and fill in your IDs (both are optional — see below)
3. Build and run, either way:
   - **Xcode:** open `youtube-music-player.xcodeproj` and press ⌘R
   - **Terminal:** `./run.sh` — copies the example into `Secrets.swift` if missing, builds Release, and launches the app

`run.sh` does a clean build each time, so it always picks up newly added source files.

## Discord Rich Presence Setup

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Create a new application
3. Copy the Application ID
4. Paste it into `Secrets.swift` as `discordClientId`

## Spotify Import Setup

Importing playlists requires your own Spotify app credentials:

1. Create an app at the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
2. Set the **Redirect URI** to `ytmusic-import://callback`
3. While the app is in Development Mode, add your Spotify account under the app's users (Spotify caps this at 5 users)
4. Copy the **Client ID** and paste it into `Secrets.swift` as `spotifyClientID`
5. Rebuild, then use the in-app **Import from Spotify** flow to connect and import

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16+ (for building)

## License

MIT
