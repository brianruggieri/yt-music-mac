# Final Review Fix Wave — Spotify→YouTube Music Import

## A — Narrow transfer-link nav interception
**File:** `youtube-music-player/YouTubeMusicWebView.swift` ~line 250  
**Change:** Added path/query discriminator before opening the import sheet. When `host == "support.google.com" || host == "help.youtube.com"`, the URL is now checked for `"transfer"` or `"musicpremium"` (case-insensitive) in `absoluteString`. If matched → import sheet; if not matched → `NSWorkspace.shared.open(url)` + cancel. Non-transfer help links now correctly open in the system browser.  
**Comment added** explaining the discriminator and upgrade path.

## B — Wire write-path diagnostic to menu item
**Files changed:**
- `youtube-music-player/Import/ImportCoordinator.swift`: Added `runWriteDiagnostic() async -> String` — snapshots YTM session, builds `YTMusicClient`, calls `YTMusicDiagnostic.runWritePreflight`, returns human-readable success/failure string. Never throws.
- `youtube-music-player/ImportLauncher.swift`: Added `@Published var isDiagnosticPresented = false` alongside existing `isPresented`.
- `youtube-music-player/youtube_music_playerApp.swift`: Added `#if DEBUG` `Button("Run YouTube Music Write Diagnostic")` in `.commands` block, sets `ImportLauncher.shared.isDiagnosticPresented = true`.
- `youtube-music-player/ContentView.swift`: Added `@State private var diagnosticResult: String?`, `.onChange(of: importLauncher.isDiagnosticPresented)` that runs `coordinator.runWriteDiagnostic()` async and populates `diagnosticResult`, and `.alert("YTM Write Diagnostic", ...)` bound to that state.

`YTMusicDiagnostic.runWritePreflight` and `deletePlaylist` are now reachable via the debug menu.

## C — Tolerate non-track Spotify playlist items (podcast episodes)
**File:** `youtube-music-player/Spotify/SpotifyClient.swift` ~line 111  
**Change:** Added a custom `init(from:)` to `TrackItem` that uses `try? c.decode(TrackObject.self, forKey: .track)` — making the inner decode failable. A podcast episode (different JSON shape, no `artists`) now yields `track == nil` rather than throwing and aborting the entire page decode. `mapTrackItem` already returns `nil` for `nil` tracks. Added explanatory comment.

## D — PKCE fail-closed on RNG failure
**File:** `youtube-music-player/Spotify/PKCE.swift` line 10  
**Change:** Replaced `_ = SecRandomCopyBytes(...)` with capturing the status and asserting `precondition(status == errSecSuccess, ...)`. A non-`errSecSuccess` return now terminates with a clear message rather than proceeding with a zero-filled (deterministic) verifier.

## E — Cancel restores a usable phase
**File:** `youtube-music-player/Import/ImportCoordinator.swift`  
**Changes:**
- `startMatching()` ~line 190: Changed `if !cancelled { phase = .review }` → `phase = .review` unconditionally. Rationale: partial `needsReview` is preserved; `.review` is the correct exit regardless of cancel, and stranding on `.matching` has no exit.
- `confirmAndImport()` ~line 280: Changed `if !cancelled { phase = .done }` → `phase = .done` unconditionally. Partial `report` is preserved and displayed in `DoneView`.  
Both changes documented with inline comments.

## F — Skip creating empty playlists
**File:** `youtube-music-player/Import/ImportCoordinator.swift` ~line 224  
**Change:** In the `confirmAndImport()` source loop, `videoIDs` collection is now done BEFORE `createPlaylist`. If `videoIDs.isEmpty`, the source is recorded in `report.failed` as "Skipped — no matched tracks to import" and the loop `continue`s without ever calling `createPlaylist`. The playlist create / add block now only runs when there are tracks to add.

## G — Pin golden SHA1 vector in SAPISIDHASH self-check
**File:** `scripts/selfcheck/SAPISIDHashSelfCheck.swift`  
**Change:** Added assertion after the existing stability check:
```swift
assert(out == "SAPISIDHASH 1_4f4b06524015ec0ceb1573e0d9c62a8ac761d9a2",
       "golden vector mismatch — payload order regression? got: \(out)")
```
Expected value: `sha1("1 SAPISID_TEST https://music.youtube.com")` = `4f4b06524015ec0ceb1573e0d9c62a8ac761d9a2`. Catches any reordering of the `timestamp sapisid origin` payload.

---

## Self-Check Results

```
PKCE self-check PASS
SAPISIDHash self-check PASS
Matcher self-check PASS
```

## Clean Build Result

```
** BUILD SUCCEEDED **
```

---

## Codex Review Wave 2 — P1 + P2 Fixes

### P1 — matching-cancel strands UI for empty/non-importable sources
**File:** `youtube-music-player/Import/ImportCoordinator.swift` line 152-155  
**Change:** Removed `if !cancelled` guard on `phase = .review` in the empty-uniqueTracks early-return. Both exit points from `startMatching()` now unconditionally set `phase = .review` (the post-task-group path was already unconditional from a prior fix wave). No return path leaves `phase == .matching`.  
**Note:** The second exit point flagged (post-task-group ~line 190) was already fixed (`phase = .review` unconditional) — only the early-return guard required this change.

### P2 — narrow transfer-playlists nav interception
**File:** `youtube-music-player/YouTubeMusicWebView.swift` line 260  
**Change:** Changed `raw.contains("transfer") || raw.contains("musicpremium")` to `raw.contains("transfer") && (raw.contains("youtubemusic") || raw.contains("musicpremium"))`. Unrelated YT Music Premium help pages (which contain "musicpremium" but no "transfer") now fall through to `NSWorkspace.shared.open` instead of opening the importer. Comment updated to document the narrowed heuristic.

### Clean Build Result

```
** BUILD SUCCEEDED **
```

**Commit:** `a3835d5` — fix: recover phase on matching-cancel for empty sources; narrow transfer-link intercept

## Codex Review Wave 3 — P1 + P2 Fixes

### P1 — ImportCoordinator state is stale on sheet re-presentation
**Files:**
- `youtube-music-player/Import/ImportCoordinator.swift`: Added `func resetForPresentation()` (line ~63) that sets `phase` to `.pickSources` if `spotifyAuth.isConnected`, else `.connect`; sets `isYTMusicSignedIn = true`; clears `needsReview`, `report`, `errorMessage`, `progress`, `autoAcceptedCount`, `selectedPlaylistIDs`, `allMatches`, `importSources`, `cancelled`, `cachedYTClient`.
- `youtube-music-player/ContentView.swift`: Added `.onChange(of: importLauncher.isPresented)` that calls `coordinator.resetForPresentation()` when transitioning to `true`. Sheet re-presentation now always starts from a clean state; the YTM-not-signed-in gate re-evaluates on the next `startMatching()` call.

### P2 — SAPISIDHASH staleness on long InnerTube runs
**Files:**
- `youtube-music-player/YTMusic/YTMusicModels.swift`: Replaced `let authorization: String` with `let sapisid: String` in `YTMusicSession`.
- `youtube-music-player/YTMusic/YTMusicAuth.swift`: Removed one-time `authorization` computation; `snapshot()` now populates `sapisid` directly from the extracted `__Secure-3PAPISID` value.
- `youtube-music-player/YTMusic/YTMusicClient.swift` (`post()` line ~92): `Authorization` header now recomputed per-request via `SAPISIDHash.authorization(sapisid: session.sapisid, origin: ..., timestamp: Int(Date().timeIntervalSince1970))`. Eliminates mid-run 401s on long imports.

### Verify

**SAPISIDHASH self-check:** `SAPISIDHash self-check PASS`

**Clean build:**
```
** BUILD SUCCEEDED **
```

---

## Notes

- context7 was NOT used — all changes were based on reading the existing codebase and stdlib knowledge.
- All A–G items fully implemented and reachable.
- The diagnostic (B) is gated under `#if DEBUG` in the menu, consistent with the spec's suggestion.

## Codex P1 + P2 — ImportCoordinator fixes (commit b49502a)

### P1 — Generation-invalidate stale in-flight tasks on reset

File: `youtube-music-player/Import/ImportCoordinator.swift`

- Added `private var runGeneration = 0` (line ~57).
- `resetForPresentation()`: bumps `runGeneration += 1` **before** clearing state (line ~68).
- `startMatching()` (line ~103): `runGeneration += 1; let gen = runGeneration` at entry. Guards added:
  - After `ytMusicAuth.snapshot()` await in do block and each catch branch (~line 128, 133, 138).
  - Per-iteration `guard !cancelled, gen == runGeneration else { break }` in playlist loop (~line 146).
  - `if gen == runGeneration` guards around per-playlist and likedSongs `@Published` mutations (~lines 149–163).
  - `guard gen == runGeneration else { return }` before `importSources = sources` (~line 167).
  - `guard gen == runGeneration else { return }` at top of `for await result in group` drain (~line 188).
  - Seeding loop and continuation check also guard on `gen == runGeneration` (~lines 183, 200).
  - `guard gen == runGeneration else { return }` before final `phase = .review` (~line 208).
- `confirmAndImport()` (line ~217): same pattern — gen set at entry, guards after session await, outer source loop, batch while loop top, after `withRetry` calls in catch branches, and before `phase = .done`.

### P2 — Reset reloads playlists; clears includeLiked

- `resetForPresentation()` now resets `includeLiked = false` (~line 78).
- When `spotifyAuth.isConnected`, sets `phase = .pickSources` and launches `Task { await loadSources() }` to repopulate `playlists` (~lines 80–84). `loadSources()` sets `playlists` and reasserts `phase = .pickSources` on success.

### Build result

`** BUILD SUCCEEDED **` (clean build, `CODE_SIGNING_ALLOWED=NO`, macOS destination)

---

## Codex P1 + P2 (second pass) — loadSources gen-guard + cancel on dismiss

### P1 — loadSources() not generation-guarded (stale write race)

File: `youtube-music-player/Import/ImportCoordinator.swift`, `loadSources()` (~line 100)

- Captured `let gen = runGeneration` at function entry (before any `await`).
- After `spotifyClient.playlists()` await: added `guard gen == runGeneration else { return }` before writing `playlists` and `phase = .pickSources`.
- In the catch branch: added same guard before writing `errorMessage`.
- Covers both callers (`resetForPresentation` Task and `connectSpotify`) — gen capture at entry handles both.

### P2 — Sheet close doesn't stop active import Task

File: `youtube-music-player/ContentView.swift`, `.onChange(of: importLauncher.isPresented)` (~line 50)

- Removed `guard presented, …` early-exit so both `true` and `false` transitions are handled.
- When `presented == true`: calls `coordinator.resetForPresentation()` (unchanged behavior).
- When `presented == false` (sheet dismissed): calls `coordinator.cancel()` — sets `cancelled = true`, which all active loops check between I/O units.
- Diagnostic alert path unaffected (separate `.onChange(of: importLauncher.isDiagnosticPresented)`).

### Build result

`** BUILD SUCCEEDED **` (clean build, `CODE_SIGNING_ALLOWED=NO`, macOS destination)
