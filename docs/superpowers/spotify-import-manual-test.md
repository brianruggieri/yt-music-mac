# Spotify→YouTube Music Import: Manual Test Plan

This document captures the human-only verification steps for the Spotify import feature. Live authentication (Spotify + YouTube Music) cannot be automated and requires a person running the app while logged in.

## Setup & Prerequisites

### Spotify Developer App Registration

- [ ] Create a Spotify app at https://developer.spotify.com/dashboard
- [ ] Set **Redirect URI** to `ytmusic-import://callback`
- [ ] Add your Spotify account as a user in the app dashboard (Development Mode, ≤5 users limit, account owner must have Premium)
- [ ] Copy the **Client ID** from the app dashboard
- [ ] Paste the Client ID into `Secrets.swift` as `spotifyClientID`
- [ ] Rebuild the app (`Cmd+B`)

### YouTube Music Sign-In

- [ ] Launch the app
- [ ] Navigate to the YT Music sign-in screen
- [ ] Complete sign-in via the embedded webview
- [ ] Verify you are logged in and can see your YT Music library (in any view)

---

## Step 1: YT Music Write-Path Diagnostic

This validates that the app has permission to write playlists to YouTube Music via InnerTube.

- [ ] **Invoke the preflight diagnostic:** Call `YTMusicDiagnostic.runWritePreflight()` from code or a debug action (e.g., via SwiftUI preview, or if a debug UI button exists, tap it)
  - *Note:* Currently no production UI button exists for this — document the gap or add a debug-only menu item if needed
- [ ] Verify the diagnostic completes without error
- [ ] The diagnostic creates a private `_import-preflight` playlist, adds a test track, and deletes it — check system logs or YT Music to confirm this temporary playlist was cleaned up
- [ ] **Result:** If the preflight returns success, write auth is working; proceed to Spotify connection

---

## Step 2: Connect Spotify Account

- [ ] Go to **File** ▸ **Import from Spotify…**
- [ ] Tap **Connect Spotify**
- [ ] Complete the Spotify OAuth flow (allow permissions)
- [ ] Verify the OAuth completes and returns to the app without errors
- [ ] Confirm playlists load in the import sheet (you should see a list of your Spotify playlists and/or Liked Songs)

---

## Step 3: Select Playlist & Review Matching

- [ ] Select a **small playlist** (5–50 tracks) to test with; alternatively select **Liked Songs**
- [ ] Tap **Next** to run the matching algorithm
- [ ] Verify the review screen loads with:
  - [ ] Count of auto-accepted matches
  - [ ] List of uncertain matches (confidence < threshold)
  - [ ] List of not-found tracks
- [ ] Confirm all track rows are visible and readable

---

## Step 4: Review Actions

Test each action on the review screen:

- [ ] **Accept** — select an uncertain match and tap Accept; verify it moves to the accepted list
- [ ] **Pick Alternate** — for a match with alternates, select one and confirm
- [ ] **Manual Search** — for a not-found track, manually search for it and add it
- [ ] **Skip** — mark a track to skip; verify it is excluded from import

---

## Step 5: Run Import

- [ ] Tap **Import**
- [ ] Verify a progress indicator appears (or other feedback; note if progress is indeterminate)
- [ ] Wait for import to complete
- [ ] Verify a "Done" report screen appears showing:
  - [ ] Number of tracks imported
  - [ ] Number of tracks skipped
  - [ ] Number of failures (if any)
- [ ] Check YouTube Music (in another app or browser) to confirm a new playlist was created with the imported tracks

---

## Step 6: Alternative Entry Point (Settings)

Test the dead-end button that now opens the import sheet:

- [ ] In YouTube Music (web or another app), go to **Settings** ▸ **Privacy & data**
- [ ] Tap **"Transfer playlists from other apps"** (or similar language)
- [ ] Verify it **opens the import sheet in this app** (not a dead-end help page or external link)
- [ ] Tap **Connect Spotify** and verify auth works
- [ ] Verify **other links in YT Music continue to open in the system browser** (not intercepted)
- [ ] Verify **YT Music login still works** (not bounced to Safari unexpectedly)

---

## Known v1 Limitations

⚠️ **Document the following known behaviors for QA and users:**

- **No cross-run deduplication:** Re-importing the same playlist creates duplicate playlists in YouTube Music; no automatic merge or replacement
- **Indeterminate import progress:** The import progress bar or indicator may not update in real-time; completion is confirmed only when the Done report appears
- **SAPISIDHASH expiration on large imports:** Imports of playlists with 2000+ tracks may fail due to YouTube session token expiration; recommend breaking large imports into smaller batches or re-authenticating

---

## Verification Checklist (Final)

- [ ] All steps above completed without crashes or UI hangs
- [ ] YT Music playlist created with correct track count and names
- [ ] No unexpected errors in system logs (`Console.app`)
- [ ] Playable tracks in YT Music (spot-check a few tracks in the YT Music app)
