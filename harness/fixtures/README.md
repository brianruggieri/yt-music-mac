# Deterministic fixtures

Freezes music.youtube.com content so the light-theme harness renders the **same
screens every run** (no rotating personalized content, no real PII), under a
consistent invented user — **Alex Rivera**.

## How it works

1. **Capture** (once, gitignored): real youtubei responses live in `capture/`
   (`browse-*`, `next`, `player`, `account_menu`, `guide`, `search*`). They contain
   real account data, so `capture/` is `.gitignore`d.
2. **Transform** (`transform.mjs`): a single recursive walker rewrites every content
   field — `musicResponsiveListItemRenderer` / `musicTwoRowItemRenderer` / queue /
   now-playing / account identity / sidebar / search — from the `fake-user.json` pool,
   points every thumbnail at a black-square sentinel, and scrubs names / avatars /
   `visitorData`. `build-fixtures.mjs` runs it over `capture/` → committable `data/*.json`.
3. **Serve** (`fixture.mjs` → `installFixture(context)`):
   - `youtubei/v1/{browse,search,next,player,account_menu,guide,...}` → the matching
     `data/*.json` (browse keyed by gunzipped `browseId`).
   - album art → 1×1 black SVG (kept a real `<img>` box so play-button/overlay
     detection still fires "over media"); avatar → `fake-avatar.svg`.
   - the SPA document → `YTMUSIC_INITIAL_DATA` emptied, so cold-loaded home/explore/
     moods/guide re-fetch via XHR and get the fake fixtures too (no in-page hooking).

## Rebuild after re-capturing

```bash
node fixtures/build-fixtures.mjs     # capture/ -> data/
```

## Use in a test / screenshot

```js
import { installFixture } from './fixtures/fixture.mjs';
await installFixture(context);       // before creating the page
```

See `demo.mjs` for a full example (`node fixtures/demo.mjs`).

## What's real vs fake

Fake: all titles, artists, albums, durations, view counts, playlists, the account
name/handle/avatar, now-playing, search results + suggestions, album art (black).
Kept: shelf section titles ("Listen again", "Quick picks"), mood chips, and opaque
`trackingParams` (load-bearing, non-personal).
