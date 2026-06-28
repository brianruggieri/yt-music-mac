# Spotify → YouTube Music Import — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native, in-app flow to import Spotify playlists + Liked Songs into YouTube Music, reusing the app's logged-in YT Music webview session, with a review step for uncertain matches.

**Architecture:** Swift owns all logic. Spotify is read via its Web API (OAuth PKCE). YT Music is written via native InnerTube (`youtubei/v1`) calls authenticated from the webview's session cookies + page `ytcfg`. A pure `Matcher` scores each Spotify track against YTM search results; high-confidence matches auto-accept, the rest go to a review UI. Entry via a `File` menu command and by intercepting YT Music's dead-end desktop "Transfer playlists" navigation.

**Tech Stack:** Swift 5, SwiftUI, WebKit (`WKWebView`/`WKHTTPCookieStore`), `ASWebAuthenticationSession`, CryptoKit, Keychain, `URLSession`.

**Reference implementation:** `ytmusicapi` (`https://github.com/sigma67/ytmusicapi`, esp. `ytmusicapi/helpers.py` and the browser-auth docs). Subagents may WebFetch these for exact InnerTube payload/header shapes.

## Global Constraints

- macOS 14.0+, Swift 5, native SwiftUI + WebKit. No Electron, no new third-party dependency unless a task explicitly adds it (none should).
- New source files go under `youtube-music-player/` (auto-included via synchronized file group). Group into subfolders: `Spotify/`, `YTMusic/`, `Import/`, `ImportUI/`.
- The project has **no XCTest target**. Pure-logic units are verified by an assert-based self-check compiled with `swiftc` from `scripts/selfcheck/`; these self-check files live OUTSIDE `youtube-music-player/` so they are never compiled into the app.
- Build/verify command (no signing needed for a compile check):
  `xcodebuild build -project youtube-music-player.xcodeproj -scheme youtube-music-player -configuration Debug CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS' -quiet`
- Spotify app stays in Development Mode (≤5 whitelisted users, owner has Premium). Auth = Authorization Code + PKCE, no client secret. Redirect = custom scheme `ytmusic-import://callback`.
- YT Music auth required cookie: `__Secure-3PAPISID` (domain `.youtube.com`). `Authorization: SAPISIDHASH {ts}_{sha1(ts + " " + 3papisid + " " + origin)}`, `origin = https://music.youtube.com`. Required headers also: `Cookie`, `Content-Type: application/json`, `Accept`, `X-Goog-AuthUser`, `Origin`, `x-origin: https://music.youtube.com`, `X-Goog-Visitor-Id`. Context = `WEB_REMIX` + WEB_REMIX InnerTube key; visitor data + context + auth-user index read live from the page `ytcfg`.
- Commit after each task with `feat:`/`chore:`/`test:` prefixes (imperative, no Co-Authored-By).

---

### Task 1: Spotify config + secrets

**Files:**
- Modify: `Secrets.example.swift` (add Spotify fields)
- Modify: `Secrets.swift` (local, gitignored — add Spotify fields)
- Create: `youtube-music-player/Spotify/SpotifyConfig.swift`

**Interfaces:**
- Produces: `enum SpotifyConfig { static let clientID: String; static let redirectURI = "ytmusic-import://callback"; static let scopes = ["playlist-read-private","playlist-read-collaborative","user-library-read"]; static let authBase = "https://accounts.spotify.com"; static let apiBase = "https://api.spotify.com/v1" }`. `clientID` reads from `Secrets.spotifyClientID`.

- [ ] **Step 1:** In `Secrets.example.swift`, add `static let spotifyClientID = "YOUR_SPOTIFY_CLIENT_ID"` to the existing `Secrets` enum/struct (match the existing Discord field style).
- [ ] **Step 2:** In `Secrets.swift` (create if missing by copying the example), add the same field with a placeholder. This file is gitignored; never commit a real ID.
- [ ] **Step 3:** Create `SpotifyConfig.swift` with the constants above, `clientID` returning `Secrets.spotifyClientID`.
- [ ] **Step 4:** Build. Run the Global-Constraints build command. Expected: BUILD SUCCEEDED.
- [ ] **Step 5:** Commit `chore: add Spotify config + secrets field` (stage only `Secrets.example.swift` and `SpotifyConfig.swift`; do NOT stage `Secrets.swift`).

---

### Task 2: SAPISIDHASH utility (pure, TDD)

**Files:**
- Create: `youtube-music-player/YTMusic/SAPISIDHash.swift`
- Create: `scripts/selfcheck/SAPISIDHashSelfCheck.swift`

**Interfaces:**
- Produces: `enum SAPISIDHash { static func authorization(sapisid: String, origin: String, timestamp: Int) -> String }` returning `"SAPISIDHASH \(timestamp)_\(sha1hex)"` where `sha1hex = sha1Hex("\(timestamp) \(sapisid) \(origin)")`. Uses `import CryptoKit` (`Insecure.SHA1`).

- [ ] **Step 1: Write the failing self-check.** Create `scripts/selfcheck/SAPISIDHashSelfCheck.swift`:
```swift
import Foundation
// Known-answer test: sha1("1 SAPISID_TEST https://music.youtube.com") hex,
// prefixed by "SAPISIDHASH 1_". Compute the expected sha1 with the same recipe.
let out = SAPISIDHash.authorization(sapisid: "SAPISID_TEST", origin: "https://music.youtube.com", timestamp: 1)
assert(out.hasPrefix("SAPISIDHASH 1_"), "prefix wrong: \(out)")
let hex = String(out.dropFirst("SAPISIDHASH 1_".count))
assert(hex.count == 40, "sha1 hex must be 40 chars, got \(hex.count): \(hex)")
assert(hex.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }, "lowercase hex expected")
// Stability: same inputs → same output
assert(out == SAPISIDHash.authorization(sapisid: "SAPISID_TEST", origin: "https://music.youtube.com", timestamp: 1))
print("SAPISIDHash self-check PASS")
```
- [ ] **Step 2: Run to verify it fails (no impl yet).**
Run: `swiftc youtube-music-player/YTMusic/SAPISIDHash.swift scripts/selfcheck/SAPISIDHashSelfCheck.swift -o /tmp/sapcheck 2>&1 | head` — Expected: compile error (SAPISIDHash undefined) OR if the file is empty, "cannot find SAPISIDHash".
- [ ] **Step 3: Implement.** Create `SAPISIDHash.swift`:
```swift
import Foundation
import CryptoKit

enum SAPISIDHash {
    static func authorization(sapisid: String, origin: String, timestamp: Int) -> String {
        let payload = "\(timestamp) \(sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }
}
```
- [ ] **Step 4: Run to verify it passes.**
Run: `swiftc youtube-music-player/YTMusic/SAPISIDHash.swift scripts/selfcheck/SAPISIDHashSelfCheck.swift -o /tmp/sapcheck && /tmp/sapcheck`
Expected: `SAPISIDHash self-check PASS`
- [ ] **Step 5:** Commit `feat: add SAPISIDHASH auth header utility`.

---

### Task 3: Data models (Spotify + YTM + match)

**Files:**
- Create: `youtube-music-player/Spotify/SpotifyModels.swift`
- Create: `youtube-music-player/YTMusic/YTMusicModels.swift`
- Create: `youtube-music-player/Import/ImportModels.swift`

**Interfaces:**
- Produces:
```swift
struct SpotifyTrack: Identifiable, Equatable { let id: String; let title: String; let artists: [String]; let album: String?; let durationMs: Int; let isrc: String? }
struct SpotifyPlaylist: Identifiable, Equatable { let id: String; let name: String; let trackCount: Int }
// YTMusic
enum YTMResultType: String { case song, video, album, playlist, artist, unknown }
struct YTMCandidate: Identifiable, Equatable { let videoId: String; let title: String; let artists: [String]; let album: String?; let durationMs: Int?; let resultType: YTMResultType; let videoType: String? ; var id: String { videoId } }
struct YTMusicSession { let cookieHeader: String; let authorization: String; let visitorId: String?; let authUser: String; let apiKey: String; let context: [String: Any] }
// Import
enum Confidence { case high, low, none }
struct MatchResult: Identifiable { let track: SpotifyTrack; var candidates: [YTMCandidate]; var chosen: YTMCandidate?; var confidence: Confidence; var id: String { track.id } }
```

- [ ] **Step 1:** Create the three model files with exactly the types above.
- [ ] **Step 2:** Build (Global-Constraints command). Expected: BUILD SUCCEEDED.
- [ ] **Step 3:** Commit `feat: add Spotify/YTMusic/import data models`.

---

### Task 4: Matcher (pure, TDD — the core)

**Files:**
- Create: `youtube-music-player/Import/Matcher.swift`
- Create: `youtube-music-player/Import/TextNormalize.swift`
- Create: `scripts/selfcheck/MatcherSelfCheck.swift`

**Interfaces:**
- Consumes: `SpotifyTrack`, `YTMCandidate`, `YTMResultType`, `Confidence`, `MatchResult` (Task 3).
- Produces: `enum Matcher { static func match(_ track: SpotifyTrack, candidates: [YTMCandidate]) -> MatchResult }`. `enum TextNormalize { static func normalize(_ s: String) -> String; static func stripSuffixes(_ s: String) -> String }`.

**Scoring rules (from spec):**
- Normalize: lowercase, strip diacritics, remove punctuation, collapse whitespace. `stripSuffixes` removes parenthetical/bracket noise like `(remastered...)`, `(feat. ...)`, `- remaster`, `(live)` markers for comparison only.
- Consider only candidates whose `resultType == .song` for auto-accept eligibility; `.video` candidates may be chosen but never yield `.high`.
- **high:** normalized(title) matches AND normalized(primary artist, i.e. artists[0]) matches AND `abs(candidateDuration - trackDuration) <= 2000ms`, on a `.song` candidate. Album NOT required (tie-breaker only when multiple songs tie).
- **low:** best candidate exists but fails one of the above (fuzzy/partial title or artist, duration off, or only non-song result).
- **none:** no candidates.
- `chosen` = best-scoring candidate (highest tier; ties broken by album match then duration closeness). For `.none`, `chosen == nil`.

- [ ] **Step 1: Write the failing self-check.** Create `scripts/selfcheck/MatcherSelfCheck.swift` covering all spec cases:
```swift
import Foundation
func song(_ t:String,_ a:String,_ d:Int,_ album:String?=nil)->YTMCandidate{YTMCandidate(videoId:UUID().uuidString,title:t,artists:[a],album:album,durationMs:d,resultType:.song,videoType:nil)}
func vid(_ t:String,_ a:String,_ d:Int)->YTMCandidate{YTMCandidate(videoId:UUID().uuidString,title:t,artists:[a],album:nil,durationMs:d,resultType:.video,videoType:"MUSIC_VIDEO_TYPE_UGC")}
let base = SpotifyTrack(id:"1",title:"Chaise Longue",artists:["Wet Leg"],album:"Wet Leg",durationMs:197000,isrc:nil)
// exact -> high
assert(Matcher.match(base, candidates:[song("Chaise Longue","Wet Leg",197500,"Wet Leg")]).confidence == .high)
// remastered suffix, album missing -> still high
assert(Matcher.match(base, candidates:[song("Chaise Longue (Remastered 2022)","Wet Leg",197000,nil)]).confidence == .high)
// wrong duration (live) -> low
assert(Matcher.match(base, candidates:[song("Chaise Longue (Live)","Wet Leg",260000,nil)]).confidence == .low)
// video-only -> low, never high
assert(Matcher.match(base, candidates:[vid("Chaise Longue","Wet Leg",197000)]).confidence == .low)
// not found -> none, chosen nil
let none = Matcher.match(base, candidates:[]); assert(none.confidence == .none && none.chosen == nil)
print("Matcher self-check PASS")
```
- [ ] **Step 2: Compile-fail.** Run: `swiftc youtube-music-player/YTMusic/YTMusicModels.swift youtube-music-player/Spotify/SpotifyModels.swift youtube-music-player/Import/ImportModels.swift youtube-music-player/Import/TextNormalize.swift youtube-music-player/Import/Matcher.swift scripts/selfcheck/MatcherSelfCheck.swift -o /tmp/matchcheck 2>&1 | head` — Expected: errors (Matcher/TextNormalize undefined).
- [ ] **Step 3: Implement** `TextNormalize.swift` then `Matcher.swift` per the scoring rules. Keep both pure (Foundation only, no WebKit).
- [ ] **Step 4: Pass.** Run the same `swiftc ... -o /tmp/matchcheck && /tmp/matchcheck`. Expected: `Matcher self-check PASS`. Iterate implementation until it passes.
- [ ] **Step 5:** Commit `feat: add track matcher with confidence scoring + self-check`.

---

### Task 5: SpotifyAuth (PKCE + Keychain)

**Files:**
- Create: `youtube-music-player/Spotify/PKCE.swift`
- Create: `youtube-music-player/Spotify/KeychainStore.swift`
- Create: `youtube-music-player/Spotify/SpotifyAuth.swift`
- Create: `scripts/selfcheck/PKCESelfCheck.swift`

**Interfaces:**
- Consumes: `SpotifyConfig`.
- Produces: `enum PKCE { static func verifier() -> String; static func challenge(for verifier: String) -> String }` (challenge = base64url(sha256(verifier))). `final class SpotifyAuth { func authorize() async throws -> String /*access token*/; func validAccessToken() async throws -> String; var isConnected: Bool }`. Tokens persisted via `KeychainStore`.

- [ ] **Step 1 (TDD the pure PKCE bit):** Create `PKCESelfCheck.swift`:
```swift
import Foundation
let v = PKCE.verifier()
assert(v.count >= 43 && v.count <= 128)
let c = PKCE.challenge(for: "dummyverifierdummyverifierdummyverifier12345")
assert(!c.contains("=") && !c.contains("+") && !c.contains("/"), "must be base64url")
print("PKCE self-check PASS")
```
- [ ] **Step 2:** Run `swiftc youtube-music-player/Spotify/PKCE.swift scripts/selfcheck/PKCESelfCheck.swift -o /tmp/pkce 2>&1 | head` → expect fail.
- [ ] **Step 3:** Implement `PKCE.swift` (CryptoKit SHA256 + base64url), `KeychainStore.swift` (`Security` framework: save/load/delete a token blob under a service key), `SpotifyAuth.swift`:
  - `authorize()`: build auth URL (`/authorize` with `response_type=code`, `client_id`, `redirect_uri`, `scope`, `code_challenge`, `code_challenge_method=S256`, `state`), run `ASWebAuthenticationSession` with callback scheme `ytmusic-import`, exchange `code` at `/api/token` for tokens, store in Keychain.
  - `validAccessToken()`: return stored token; if expired, refresh via `grant_type=refresh_token`; if refresh fails, throw `needsReauth`.
  - Register the `ytmusic-import` URL scheme in the target via `Info` plist key `CFBundleURLTypes` (set in build settings `INFOPLIST_KEY_*` or an `Info.plist`; if the project uses generated Info.plist, add `CFBundleURLTypes` through an `Info.plist` file referenced by the target). Document in code comments.
- [ ] **Step 4:** Run `swiftc youtube-music-player/Spotify/PKCE.swift scripts/selfcheck/PKCESelfCheck.swift -o /tmp/pkce && /tmp/pkce` → `PKCE self-check PASS`. Then run the full `xcodebuild build` → BUILD SUCCEEDED.
- [ ] **Step 5:** Commit `feat: add Spotify PKCE OAuth + keychain token store`.

---

### Task 6: SpotifyClient (playlists + liked songs)

**Files:**
- Create: `youtube-music-player/Spotify/SpotifyClient.swift`

**Interfaces:**
- Consumes: `SpotifyAuth`, `SpotifyConfig`, `SpotifyTrack`, `SpotifyPlaylist`.
- Produces: `final class SpotifyClient { init(auth: SpotifyAuth); func playlists() async throws -> [SpotifyPlaylist]; func tracks(playlistID: String) async throws -> [SpotifyTrack]; func likedSongs() async throws -> [SpotifyTrack] }`.

- [ ] **Step 1:** Implement with `URLSession`, `Authorization: Bearer <token>` from `auth.validAccessToken()`. Paginate `GET /me/playlists` (limit 50), `GET /playlists/{id}/tracks` (limit 100, follow `next`), `GET /me/tracks` (limit 50, follow `next`). Map response → models; pull `track.external_ids.isrc` into `SpotifyTrack.isrc`. Use `Codable` response structs.
- [ ] **Step 2:** Build → BUILD SUCCEEDED.
- [ ] **Step 3:** Commit `feat: add Spotify client for playlists + liked songs`.

*(No live unit test — requires real Spotify auth. Covered by the manual test plan.)*

---

### Task 7: YTMusicAuth (cookie snapshot + ytcfg + headers)

**Files:**
- Create: `youtube-music-player/YTMusic/YTMusicAuth.swift`

**Interfaces:**
- Consumes: `SAPISIDHash`, `YTMusicSession`, the live `WKWebView`.
- Produces: `final class YTMusicAuth { init(webView: WKWebView); func snapshot() async throws -> YTMusicSession }`. Throws `.notSignedIn` if `__Secure-3PAPISID` absent.

- [ ] **Step 1:** Implement `snapshot()`:
  - Read cookies: `await webView.configuration.websiteDataStore.httpCookieStore.allCookies()`; filter by name `__Secure-3PAPISID` across domain containing `youtube.com` (not host-exact). Build the full `Cookie:` header string from all `*.youtube.com`/`music.youtube.com` cookies.
  - If `__Secure-3PAPISID` missing → throw `.notSignedIn`.
  - Build `Authorization` via `SAPISIDHash.authorization(sapisid: 3papisid, origin: "https://music.youtube.com", timestamp: Int(Date().timeIntervalSince1970))`.
  - Read `ytcfg` from the page via `webView.evaluateJavaScript("JSON.stringify({key: window.ytcfg.get('INNERTUBE_API_KEY'), ctx: window.ytcfg.get('INNERTUBE_CONTEXT'), visitor: window.ytcfg.get('VISITOR_DATA'), user: (window.ytcfg.get('SESSION_INDEX')||'0')})")`. Parse JSON → `apiKey`, `context`, `visitorId`, `authUser`. (One-shot read; the only JS in this feature.)
  - Return `YTMusicSession`.
- [ ] **Step 2:** Build → BUILD SUCCEEDED.
- [ ] **Step 3:** Commit `feat: add YTMusic auth snapshot (cookies + ytcfg + signed headers)`.

---

### Task 8: YTMusicClient (search/create/edit/delete) + write-path diagnostic

**Files:**
- Create: `youtube-music-player/YTMusic/YTMusicClient.swift`
- Create: `youtube-music-player/YTMusic/YTMusicDiagnostic.swift`

**Interfaces:**
- Consumes: `YTMusicSession`, `YTMCandidate`, `YTMResultType`.
- Produces: `final class YTMusicClient { init(session: YTMusicSession); func search(_ query: String) async throws -> [YTMCandidate]; func createPlaylist(title: String, privacy: String) async throws -> String /*playlistId*/; func addItems(playlistID: String, videoIDs: [String]) async throws -> (added: [String], failed: [String]); func deletePlaylist(_ id: String) async throws }`. `enum YTMusicDiagnostic { static func runWritePreflight(_ client: YTMusicClient) async -> Result<Void, Error> }`.

- [ ] **Step 1:** Implement InnerTube POSTs to `https://music.youtube.com/youtubei/v1/<endpoint>?key=<apiKey>` with the session headers (Authorization, Cookie, Content-Type json, Accept, X-Goog-AuthUser, Origin, x-origin, X-Goog-Visitor-Id) and a body `{ "context": <session.context>, ... }`. Endpoints: `search` (parse `musicShelfRenderer`/`musicResponsiveListItemRenderer` → candidates with `resultType`/`videoType`), `playlist/create`, `browse/edit_playlist` (action `ACTION_ADD_VIDEO`, batched), `playlist/delete`. WebFetch `ytmusicapi` `helpers.py`/mixins for exact body shapes.
- [ ] **Step 2:** Implement `YTMusicDiagnostic.runWritePreflight`: create a private playlist named `"_import-preflight"`, add one known-good videoID, then `deletePlaylist`. Return `.success` only if create+add+delete all succeed; otherwise `.failure` with the precise failing step/HTTP status. (This is the spec-required write-path validation — search alone is insufficient.)
- [ ] **Step 3:** Build → BUILD SUCCEEDED.
- [ ] **Step 4:** Commit `feat: add YTMusic InnerTube client + write-path diagnostic`.

---

### Task 9: ImportCoordinator (orchestration, rate limit, abort)

**Files:**
- Create: `youtube-music-player/Import/ImportCoordinator.swift`

**Interfaces:**
- Consumes: `SpotifyClient`, `YTMusicClient`, `YTMusicAuth`, `Matcher`, all models.
- Produces: `@MainActor final class ImportCoordinator: ObservableObject` with `@Published` state for the UI: `phase` (connect/pick/matching/review/importing/done), `playlists`, `selectedPlaylists`, `includeLiked`, `progress`, `needsReview: [MatchResult]`, `autoAcceptedCount`, `report`. Methods: `connectSpotify()`, `loadSources()`, `startMatching()`, `confirmAndImport()`, `cancel()`.

- [ ] **Step 1:** Implement orchestration:
  - `startMatching`: gather selected Spotify tracks; for each, `YTMusicClient.search("\(artist) \(title)")` then `Matcher.match`. Run searches through a **bounded task group (max ~4 concurrent)**, not one-per-track unbounded. Partition results: `.high` → auto-accept (count + remember chosen), `.low`/`.none` → `needsReview`.
  - `confirmAndImport`: create one YTM playlist per source (title from Spotify), `addItems` in batches; collect added/failed into `report`. Liked Songs → a playlist named "Spotify Liked Songs" (YTM has no writable "liked" equivalent via this path).
  - Backoff: on thrown rate-limit/5xx in search or add, retry with exponential backoff (respect `Retry-After` if present).
  - `cancel()`: set a flag checked between requests; stops issuing new work, preserves partial `report`/`needsReview`.
- [ ] **Step 2:** Build → BUILD SUCCEEDED.
- [ ] **Step 3:** Commit `feat: add import coordinator (matching, batching, abort)`.

---

### Task 10: Import UI (SwiftUI sheet)

**Files:**
- Create: `youtube-music-player/ImportUI/ImportSheet.swift` (container, switches on `coordinator.phase`)
- Create: `youtube-music-player/ImportUI/ConnectView.swift`
- Create: `youtube-music-player/ImportUI/PickSourcesView.swift`
- Create: `youtube-music-player/ImportUI/MatchingView.swift`
- Create: `youtube-music-player/ImportUI/ReviewView.swift`
- Create: `youtube-music-player/ImportUI/DoneView.swift`

**Interfaces:**
- Consumes: `ImportCoordinator` (as `@ObservedObject`/`@StateObject`).
- Produces: `struct ImportSheet: View { @ObservedObject var coordinator: ImportCoordinator }`.

- [ ] **Step 1:** Build the staged sheet:
  - **Connect:** "Connect Spotify" button → `coordinator.connectSpotify()`. Also a gate message if YT Music not signed in.
  - **PickSources:** list playlists with checkboxes + a "Liked Songs" toggle; "Continue" → `startMatching()`.
  - **Matching:** progress bar bound to `coordinator.progress`.
  - **Review:** `List(coordinator.needsReview)` rows showing Spotify track → chosen YTM candidate side by side, a confidence badge, and per-row actions: Accept, pick alternate (menu of `candidates`), Search manually (text field → `YTMusicClient.search`), Skip. Header shows `autoAcceptedCount` auto-accepted. "Import" → `confirmAndImport()`.
  - **Done:** report — imported / skipped / failed counts + a disclosure list of failures with reasons.
- [ ] **Step 2:** Build → BUILD SUCCEEDED.
- [ ] **Step 3:** Commit `feat: add Spotify import SwiftUI flow`.

*(Visual polish pass happens during review; this task is functional structure.)*

---

### Task 11: Entry points (menu command + nav interception)

**Files:**
- Modify: `youtube-music-player/youtube_music_playerApp.swift` (add `Commands`)
- Modify: `youtube-music-player/ContentView.swift` (present sheet, own the coordinator)
- Modify: `youtube-music-player/YouTubeMusicWebView.swift` (expose `webView`; add nav policy to existing `Coordinator`)

**Interfaces:**
- Consumes: `ImportCoordinator`, `ImportSheet`, `YTMusicAuth`, the live `WKWebView`.

- [ ] **Step 1:** In `YouTubeMusicViewModel`/`Coordinator` (`YouTubeMusicWebView.swift`), expose the created `WKWebView` so `YTMusicAuth(webView:)` can use it. Add `webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler:)` **to the existing Coordinator** (do not add a second delegate). Logic: if target URL host is not `music.youtube.com`: if it is the "Transfer playlists" help destination (host `support.google.com`/`help.youtube.com` reached from the transfer entry) → `.cancel` and trigger the import sheet via a published flag/NotificationCenter; for any other off-site host → `.cancel` and `NSWorkspace.shared.open(url)`. Otherwise `.allow`. Preserve existing `trackInfo` script-message behavior.
- [ ] **Step 2:** In `ContentView.swift`, own `@StateObject ImportCoordinator`, present `.sheet(isPresented:)` with `ImportSheet`, bound to a shared "show import" flag set by either the menu command or the nav interception.
- [ ] **Step 3:** In `youtube_music_playerApp.swift`, add a `.commands { CommandGroup(after: .newItem) { Button("Import from Spotify…") { /* set shared show-import flag */ } } }` wired to the same flag.
- [ ] **Step 4:** Build → BUILD SUCCEEDED.
- [ ] **Step 5:** Commit `feat: wire import entry points (menu + transfer-button interception)`.

---

### Task 12: Manual test plan doc (handoff for live verification)

**Files:**
- Create: `docs/superpowers/spotify-import-manual-test.md`

- [ ] **Step 1:** Write the steps the human must do (cannot be automated): register a Spotify app, set redirect URI `ytmusic-import://callback`, whitelist the user, put the client ID in `Secrets.swift`; sign into YT Music in the app; run the YT Music write-path diagnostic and confirm success; run a real import of a small playlist and verify the review screen + resulting YTM playlist; confirm the dead-end "Transfer playlists" button now opens the import sheet.
- [ ] **Step 2:** Commit `docs: add Spotify import manual test plan`.

---

## Self-Review

- **Spec coverage:** SpotifyAuth/Client (T5,T6) ✓; YTMusicAuth/Client + diagnostic incl. `playlist/delete` (T7,T8) ✓; Matcher confidence model + resultType (T4) ✓; ImportCoordinator rate-limit/abort (T9) ✓; staged review UI (T10) ✓; menu + nav interception entry points + strand-bug fix (T11) ✓; auth-snapshot timing/`__Secure-3PAPISID`/`.youtube.com`/SAPISIDHASH origin/X-Goog-AuthUser derivation (T7, Global Constraints) ✓; custom-scheme redirect (T1,T5) ✓; distribution/sandbox (Global Constraints, T12) ✓.
- **Verification ceiling:** live Spotify/YTM auth is inherently manual (T12); autonomous loop verifies compile + pure-logic self-checks + Codex review.
- **Type consistency:** model names/signatures in T3 are referenced unchanged by T4–T11.
