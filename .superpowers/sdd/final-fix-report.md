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
