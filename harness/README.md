# Light-theme test harness (Playwright + WebKit)

Drives `music.youtube.com` under **WebKit** (same engine family as the app's
WKWebView), injects **the exact light-theme engine the app ships**, and for every
defined screen × theme it:

1. **screenshots** it (visual-regression baseline), and
2. runs an **independent contrast audit** (WCAG 1.4.3 text + APCA Lc, plus best-effort
   1.4.11 surface contrast) — verifying the engine's output from the *outside*.

This is the "defined coverage" net: the list in [`screens.js`](./screens.js) is the
answer to *"do we have all screens/items defined for review?"* — grow it to grow coverage.

## Why WebKit (not Chromium)

Our app renders in a WKWebView. WebKit's contrast/rendering matches what users see;
Chromium wouldn't. Trade-off: WebKit has no Chrome DevTools Protocol, so we can't use
`DOMSnapshot`/`forcePseudoState`. Instead the audit runs **in-page** via `page.evaluate`
(YT Music uses Shady/light DOM, so a plain DOM walk reaches everything), and hover/focus
states are driven with real `.hover()`.

## Single source of truth

The engine is **not duplicated** here. [`lib/engine.js`](./lib/engine.js) extracts the JS
straight out of `../youtube-music-player/LightThemeEngine.swift`, so the harness always
tests the code the app actually runs.

## Setup

```bash
cd harness
nvm use            # Node 22 (see repo CLAUDE.md)
npm install
npm run setup      # installs the WebKit browser for Playwright
```

## Auth (for Home/Library + the modal tests)

**Google blocks sign-in in automation-controlled browsers** ("This browser or app may
not be secure" — in *both* WebKit and Chrome-for-Testing). Don't fight it. Instead, import
the session you already have in your normal browser:

1. In your everyday browser (logged in to YouTube Music), install **Cookie-Editor**.
2. Open <https://music.youtube.com>, then Cookie-Editor → **Export → Export as JSON** →
   save to `harness/cookies.json`.
3. Convert it to a Playwright session:
   ```bash
   npm run import-cookies cookies.json     # writes auth.json (prints "logged-in signal: true")
   export YTM_AUTH=./auth.json
   npm test
   ```

`auth.json` and `cookies.json` are gitignored — never commit them.

Without any auth, Explore/Search/Moods still render and are audited; the modal tests skip.

### Using a throwaway account for the CI canary

The weekly canary can run logged in via the `YTM_AUTH_JSON` repo secret (paste the whole
contents of `auth.json`). **Use a throwaway Google account, never your own** — the canary
uploads its Playwright report as a public artifact, and the account-menu capture in it shows
the display name, the email address, and the avatar. Real playlists and a real profile photo
have leaked into this repo's history once already.

So, on the throwaway:

- **Display name** something like `YTM Canary`, not a human name. **Leave the avatar as the
  default letter tile** — don't upload a photo.
- **No subscription needed.** Every surface the canary touches (library, playlists, settings,
  context menus, add-to-playlist, share) is free-tier. Premium only buys background play,
  downloads, and ad removal. If free-tier ad surfaces ever start throwing contrast noise,
  that's the one reason to reconsider.
- **Seed it, or the tests still skip.** The openers need something to open: a couple of
  playlists (`add-to-playlist`), some library content (`sort-menu`), track rows on Home
  (`track-context-menu`, `share-panel`), and some listening history (the `self-mix` personal
  mix card is generated). Keep it boring — it all ends up in the artifact.
- Sign in to it in a **separate browser profile**, so exporting its cookies doesn't mean
  signing out of your real account.

Refreshing it is the same import flow above, then update the secret. Expect to redo it
periodically: Google kills sessions on password change, "sign out of all devices", and
security events, and the runners hit YouTube from rotating datacenter IPs, which doesn't
help. The canary now prints a `::warning` on any run where the session isn't live, so a
dead secret shows up on the run instead of silently halving coverage — that check looks for
a live YouTube login cookie, not just a non-empty secret, because an *expired* session is
still a perfectly non-empty string.

Two housekeeping notes on the account itself: keep the password in a manager with a recovery
address you own (and the backup codes, if you enable 2FA — locking yourself out means
recreating and re-seeding the whole thing), and sign in manually once or twice a year, since
Google reclaims accounts after about two years of inactivity.

## Run

```bash
npm test                       # both themes, all screens + modals
npm test -- --project=light    # just the light theme
npm run update                 # accept new/changed screenshots as baselines
npm run report                 # open the HTML report (screenshots + diffs + logs)
```

First run creates baselines (no diff to compare against yet). Commit the baselines in
`snapshots/` so future runs catch regressions — including any future YT redesign that
breaks our theme.

## Local gate (pre-push)

The regression gate runs on your machine, not per-PR in GitHub Actions. Enable it once:

```bash
git config core.hooksPath .githooks
```

Then every `git push` that touches `LightThemeEngine.swift`, `YouTubeMusicWebView.swift`,
or `harness/**` runs `npm test` first and blocks the push on failure (skip a single push with
`git push --no-verify`). The GitHub workflow (`light-theme-gate.yml`) is kept only as a
post-merge backstop on `main` + a manual `workflow_dispatch`. The live canary
(`light-theme-canary.yml`) still runs weekly against real YouTube.

## What it gates

- **Text contrast (1.4.3)** failures **fail the build** in light mode.
- **Surface contrast (1.4.11)** is **reported, not yet gating** (best-effort heuristic —
  see the long discussion about why identifying "the card surface" is hard).
- **Visual diffs** fail when a screenshot drifts past `maxDiffPixelRatio` (tune per screen).

## Extending coverage

- Add routes to `SCREENS` in `screens.js`.
- Add modal/menu openers to `INTERACTIONS` (each clicks a trigger and leaves the surface open).
- The TODO list there names the obvious gaps: add-to-playlist, share, settings, queue,
  now-playing page, sort/filter menus.

## CI (next step)

Wire `npm test` into a scheduled GitHub Action (it needs no Xcode — just Node + WebKit).
On failure it uploads the HTML report; a recurring run becomes the **canary** that catches
a Google redesign breaking the theme before users do.
