# Spotify → YouTube Music Import — Design

**Date:** 2026-06-28
**Status:** Approved design, pre-implementation
**App:** `yt-music-osx` — native macOS (Swift + WebKit) wrapper for YouTube Music

## Goal

A polished, native, in-app flow to import a user's Spotify playlists and Liked
Songs into YouTube Music, reusing the app's already-authenticated YT Music
webview session. The user reviews only the matches that are *uncertain*, so
wrong-version substitutions (live/remix swapped for studio — the failure mode
third-party tools hide) get caught before import.

### Why build this at all

YouTube Music ships an official transfer feature (powered by Tune My Music, free
for Premium) — but **only in the mobile app**. On desktop web (what this app
renders) the "Transfer playlists from other apps" entry under Settings → Privacy
& data is a dead-end link to a help article; there is no working transfer flow.
So there is a genuine desktop gap. We build a native flow rather than surfacing
Tune My Music because owning the in-app experience — and catching the
silent-wrong-version matches the third-party tools don't surface — is the point.

## Distribution posture

- **v1: personal / small.** Spotify app stays in **Development Mode**: ≤5
  whitelisted accounts (added by email in the dashboard), and the **app owner
  must have Spotify Premium**. No approval process; ships immediately.
- **Public is effectively closed for an indie — do not assume a later
  checkbox.** As of 2026, Extended Quota Mode is granted **only to
  organizations** (not individuals), with stated requirements including ~250k
  MAU and review up to ~6 weeks
  (https://developer.spotify.com/documentation/web-api/concepts/quota-modes).
  So "public" is a real business/distribution blocker, not a config step. The
  code is built clean (PKCE, no secret) so it *could* go public if that path
  ever opens, but v1 targets personal use and we don't design around a public
  launch we can't currently get.
- Spotify auth uses **Authorization Code + PKCE**, no embedded client secret.
  Redirect strategy: **custom URL scheme** (e.g. `ytmusic-import://callback`)
  with `ASWebAuthenticationSession` — simpler than a loopback HTTP server (no
  local-server lifecycle / firewall failure modes). The token request
  `redirect_uri` must exactly match the authorization request.

## Architecture

Swift owns all logic. The webview is used only as the source of the
authenticated YT Music session (cookies); InnerTube calls are made natively from
Swift — no JavaScript in the import hot path.

### Modules (each isolated, single responsibility)

1. **`SpotifyAuth`**
   - PKCE OAuth via `ASWebAuthenticationSession`.
   - Tokens stored in the Keychain; silent refresh on expiry.
   - Scopes: `playlist-read-private`, `playlist-read-collaborative`,
     `user-library-read`.
   - Output: a valid access token.

2. **`SpotifyClient`**
   - Reads playlists (`GET /me/playlists`, `GET /playlists/{id}/tracks`) and
     Liked Songs (`GET /me/tracks`), with pagination.
   - Depends on `SpotifyAuth`.
   - Output: `[SpotifyTrack]` — `{ id, title, artists[], album, durationMs, isrc }`.

3. **`YTMusicClient`** (native InnerTube) — **highest-risk module; auth is NOT
   cookie-only.** Replicates exactly what the YT Music page normally provides.
   - **Auth snapshot** (see `YTMusicAuth` below): reads cookies from
     `webView.configuration.websiteDataStore.httpCookieStore` **after** an
     authenticated `music.youtube.com` page has loaded — not at app launch. The
     store is async (`getAllCookies`) and can lag login; the snapshot must wait
     for page load and confirm the required cookie exists.
   - **Required cookie:** `__Secure-3PAPISID` specifically (not plain
     `SAPISID`). Cookie **domain is `.youtube.com`**, so filter by name across
     the `.youtube.com` domain — host-filtering `music.youtube.com` misses it.
   - **`Authorization` header:** `SAPISIDHASH {ts}_{sha1(ts + " " + 3papisid + " " + origin)}`
     where `origin = https://music.youtube.com`. Never compute against
     `youtube.com` / `accounts.google.com` / a guessed origin.
   - **Other required headers:** `Cookie`, `Content-Type: application/json`,
     `Accept`, `X-Goog-AuthUser`, `Origin` +
     `x-origin: https://music.youtube.com`, and `X-Goog-Visitor-Id`.
     **`X-Goog-AuthUser` derivation:** the active signed-in user index — read it
     from the page session (the value YT Music itself sends, in the
     `ytcfg`/session state) rather than assuming `0`, so multi-account ("Brand
     Account") logins target the right account.
   - **Context + key:** `WEB_REMIX` `INNERTUBE_CONTEXT` and the WEB_REMIX
     InnerTube API key. **Visitor data** (`X-Goog-Visitor-Id`) and the context
     are pulled live from the page's `ytcfg` bootstrap via a one-shot injected
     JS read (the only JS in this feature — a read, not the hot path), so they
     stay in sync with what the server expects rather than being hardcoded.
   - Calls `youtubei/v1` via `URLSession`: `search`, `playlist/create`,
     `browse/edit_playlist` (add items), and `playlist/delete` (used **only** by
     the write-path auth diagnostic to clean up its throwaway playlist; the
     import flow itself never deletes).
   - Ported from the `ytmusicapi` reference implementation (`helpers.py`).
   - Output: search candidates, created playlist id, per-add success/failure.
   - **Risk:** without the full header/context/visitor set, `search` may work
     inconsistently while `playlist/create` / `edit_playlist` fail with 401/403
     or land on the wrong account. Validate end-to-end early (see Testing).

   **`YTMusicAuth`** (sub-component of the YT Music side; isolated so the
   diagnostic can target it). Owns the **auth snapshot**: given the live
   `webView`, waits for an authenticated `music.youtube.com` load, reads the
   cookie store, extracts `__Secure-3PAPISID` (domain `.youtube.com`), pulls
   `ytcfg` context + visitor data via the one-shot JS read, and produces the
   signed header set (`Authorization` SAPISIDHASH, `X-Goog-AuthUser`,
   `x-origin`, `X-Goog-Visitor-Id`, etc.) that `YTMusicClient` attaches to every
   request. Surfaces a clear "not signed in / missing X" state. Output: a
   ready-to-use `YTMusicSession` or a precise failure reason.

4. **`Matcher`** — **pure, no I/O. The testable core.**
   - Input: one `SpotifyTrack` + that track's YTM search results.
   - Output: ranked `[YTMCandidate]` + a `Confidence`.
   - Normalizes metadata, strips `(Remastered)` / `feat.` / similar suffixes,
     fuzzy-matches with word reordering, weights duration proximity, and
     **avoids video results** (catalog songs only) — the `linsomniac` approach
     (~99% of tracks that exist on YTM, ~0% wrong).
   - Owns the project's primary unit tests.

5. **`ImportCoordinator`** (ObservableObject / ViewModel)
   - Orchestrates the run: read Spotify → for each track, search YTM + score →
     partition into **auto-accept (high confidence)** vs **needs-review
     (low / none)** → after user review, create the playlist and add items →
     emit a final report.
   - Owns progress and error state for the UI.

6. **UI** — one native SwiftUI sheet, staged:
   - **Connect Spotify** → OAuth.
   - **Pick sources** → choose playlists + toggle Liked Songs.
   - **Matching** → progress while searching/scoring.
   - **Review** → flagged (low/none) tracks only; auto-accepted shown as a count.
   - **Import** → progress while creating playlist + adding items.
   - **Done** → report (imported / skipped / failed, with reasons).

7. **Entry points** (both need new plumbing — none exists today)
   - **(A) Menu command:** `File ▸ Import from Spotify…` via a SwiftUI
     `Commands` block. The app currently has no `Commands`; the command toggles
     shared state (e.g. `@Published showImport` on an app-level coordinator /
     the existing `YouTubeMusicViewModel`) that `ContentView` observes to present
     the sheet. The coordinator must expose the live `webView` so `YTMusicAuth`
     can read its cookie store.
   - **(B) Navigation interception:** the **existing** `Coordinator`
     (`YouTubeMusicWebView.swift`) is already assigned as `navigationDelegate`
     but implements no policy method. Add
     `webView(_:decidePolicyFor:decisionHandler:)` **to that same coordinator**
     (do not introduce a second delegate — it would silently break the existing
     `trackInfo` script-message flow). Policy:
     - the dead-end "Transfer playlists from other apps" navigation →
       cancel + present our import sheet;
     - any other navigation off `music.youtube.com` → cancel + open in the
       system browser (also fixes the existing "stranded on a help page with no
       back button" bug).

### Data model

```
SpotifyTrack  { id, title, artists[], album, durationMs, isrc? }
YTMCandidate  { videoId, title, artists[], album, durationMs, resultType, videoType }
MatchResult   { spotifyTrack, candidates[], chosen?, confidence }
Confidence    = high | low | none
```

## Confidence model (fixed thresholds, v1)

- **Hard gate for `high` (auto-accept):** normalized **title + primary artist**
  match *and* duration within ~2s, on a **catalog song** result. **Album is a
  bonus/tie-breaker only, never required** — YTM album metadata is frequently
  absent, localized, deluxe/remaster-specific, or single-vs-album mismatched, so
  requiring it would wrongly demote good matches.
- **low → review:** fuzzy/partial title-or-artist match, duration mismatch, or
  only a non-catalog result available.
- **none → review:** nothing found.

**Result-type contract (not just `isVideo`).** YTM `search` returns songs,
videos, uploads, official music videos, and community playlists with overlapping
fields. `isVideo` alone is too thin: parse and store `resultType` / `videoType`,
and only **auto-accept catalog song-like results**. Video-only matches stay
reviewable (never auto-accepted).

ISRC is available on the Spotify side, but YTM search results do not reliably
expose ISRC, so v1 scores on text + duration only. An ISRC cross-check (via a
per-candidate `browse`) is a possible later enhancement, not v1.

## Review screen (the polish surface)

Per-track rows, each showing **Spotify track → matched YT Music track** side by
side, a confidence indicator, and inline actions:

- **Accept** the suggested match.
- **Pick an alternate** from the other candidates.
- **Search YT Music manually** (free-text → live `search`).
- **Skip** the track.

Only flagged tracks appear; auto-accepted tracks are summarized as a count with
an option to expand/review them if desired.

## Error handling, rate limiting, abort

- **Not signed into YT Music** (auth snapshot missing `__Secure-3PAPISID`) →
  friendly gate: "Sign in to YouTube Music first," blocking until resolved.
- **Spotify token expired** → silent refresh; hard failure → re-auth prompt.
- **Rate limiting (designed, not just named):**
  - **bounded concurrency** on YTM `search` (a small fixed pool, not one request
    per track in parallel);
  - **exponential backoff** on HTTP 429 / 5xx (respect `Retry-After`);
  - **batch** playlist edits where `edit_playlist` supports multiple adds per
    call rather than one call per track.
- **Per-track failures never abort the run** — they are collected into the
  report.
- **Abort/cancel path:** the user can cancel mid-run; cancellation stops issuing
  *new* requests but preserves the partial review/import report (what matched,
  what imported, what's left) so nothing silently vanishes.
- **Partial import** (playlist created, some adds failed) → report lists exactly
  which tracks failed and why.

## Testing

- **`Matcher`**: real unit tests — canned `SpotifyTrack` + canned YTM results →
  asserted confidence and chosen candidate. Must cover: exact match, suffix
  variants (Remastered/feat.), wrong-duration live version (→ low), video-only
  / non-catalog result (→ low, never auto-accepted), album-missing-but-otherwise-exact
  (→ high), and not-found (→ none).
- **`SpotifyClient` / `YTMusicClient`**: thin parse smoke tests (canned API
  response → data model).
- **YT Music auth diagnostic (required — the parse tests don't cover the hard
  part).** A debug command that reads the live webview cookies, builds the full
  header/context/visitor set, and reports exactly which cookie / header /
  context piece is missing or rejected. **It must validate the WRITE path, not
  just `search`** — search auth is laxer, so a half-authenticated session can
  return search results while `playlist/create` / `edit_playlist` 401/403. The
  diagnostic performs a controlled write preflight: create a throwaway **private**
  playlist, add one track, then delete it — confirming the endpoints the import
  actually depends on. This is the fastest way to catch auth-replication
  failures before they surface mid-import.
- **UI**: manual QA.

## Out of scope for v1 (deferrable without rework)

- Albums / followed artists.
- Two-way or ongoing sync.
- Dedup against existing YTM playlists / re-run idempotency.
- Public-distribution Spotify Extended Quota approval.
- ISRC-based matching.

## Known risks (highest first)

- **YT Music auth replication is the #1 build risk.** Cookie-only is not enough;
  the full header + `ytcfg` context + visitor-data set must match what the page
  sends, or writes fail with 401/403 / wrong-account. Mitigation: the
  `YTMusicAuth` snapshot reads context/visitor live from the page, and the auth
  diagnostic validates the whole set against a real request before any import.
- **InnerTube is unofficial** (`youtubei/v1`), against YouTube ToS in spirit; can
  break when Google changes endpoints or the `WEB_REMIX` context/key. Track
  upstream `ytmusicapi` (`helpers.py`). Acceptable for a personal-use wrapper.
- **Public distribution is effectively blocked**, not gated: Extended Quota is
  org-only (~250k MAU, ~6-week review). Personal v1 is unaffected; a public
  launch is out of reach without becoming a qualifying organization.
- **Sandbox is currently disabled** (per `youtube_music_player.entitlements`),
  which is fine — it does **not** block `ASWebAuthenticationSession` or Keychain,
  and avoids some sandbox-entitlement friction. Not a v1 concern. Only revisit
  (associated domains / custom-scheme registration / Keychain access groups /
  network entitlements) if this ever targets the Mac App Store or hardened
  notarized distribution.
