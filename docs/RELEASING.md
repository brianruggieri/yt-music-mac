# Release pipeline

How **YouTube Music for macOS** (this fork, `brianruggieri/yt-music-mac`) is built and shipped,
what we inherited from upstream, and the signing / legal considerations behind the design.

---

## TL;DR — how to cut a release

```bash
# 1. Bump the version and tag it
scripts/release/bump-version.sh 1.2.0 --tag

# 2. Push the commit and the tag
git push origin main
git push origin v1.2.0
```

Pushing the `v*` tag triggers `.github/workflows/release.yml`, which builds a universal
(Apple Silicon + Intel) app, signs/notarizes it **if** the relevant secrets are configured,
packages a `.zip` + `.dmg` + `SHA256SUMS.txt`, and publishes a GitHub Release with generated
notes. No secrets required for a first release — it just ships an ad-hoc build (see tiers below).

You can also run the workflow manually (**Actions → release → Run workflow**): enter a version and
leave **publish** off for a dry-run (build + downloadable artifacts, no Release). Tick **publish**
to cut the release from the Actions UI — the workflow creates the `v<version>` tag itself using the
runner token, which is the path to use in environments where direct `git push`-ing a tag is blocked.

---

## What we forked from

Upstream is **[`0xjemm/youtube-music-macos`](https://github.com/0xjemm/youtube-music-macos)**
(MIT). Its release model:

- **Manual GitHub Releases** — the `.app` is zipped and uploaded by hand; there is no build
  automation in the upstream repo (only issue templates).
- **A hand-maintained Homebrew cask** in a companion tap,
  `0xjemm/homebrew-youtube-music-macos`, updated manually per release.
- **Un-notarized builds.** The install instructions tell users to run
  `xattr -cr "/Applications/YouTube Music.app"`, which is the tell that the app is not
  Apple-notarized (and likely only ad-hoc signed). That's normal for a hobby macOS app: Apple
  notarization needs a paid Developer account.

So "the pipeline we inherited" is essentially **build locally → drag a zip into a Release →
edit a Ruby cask by hand.**

## What our fork had before this change

- **No releases** (`Releases` was empty) and **no build/release automation**.
- Two CI workflows, both **quality gates rather than a pipeline**:
  - `light-theme-gate.yml` — deterministic WebKit screenshot/contrast regression suite, run
    mostly via a local `pre-push` hook to save macOS Actions minutes.
  - `light-theme-canary.yml` — weekly run against live `music.youtube.com` to catch YT
    redesigning their DOM.
- Local build via `run.sh` (`xcodebuild … -configuration Release`).
- **Automatic** code-sign style with **no Development Team** set → CI would fail automatic
  signing; builds are effectively ad-hoc.

This change adds the actual build-and-ship pipeline on top of those gates.

---

## The pipeline

```
 tag v* ──▶ release.yml (macos-15)
              │
              ├─ make-secrets.sh      Secrets.swift from CI secrets (or placeholders)
              ├─ import cert          Developer ID → temp keychain      [Tier 1 only]
              ├─ build-app.sh         universal Release .app (Hardened Runtime if signing)
              ├─ notarize.sh          notarytool submit --wait + staple  [Tier 1+ only]
              ├─ package.sh           .zip + .dmg + SHA256SUMS.txt
              ├─ upload-artifact      always (even on manual runs)
              └─ action-gh-release    publish Release + assets           [tag pushes only]
                    │
                    └─▶ homebrew job   bump the cask in your tap         [if configured]
```

Everything lives in small, separately runnable scripts under `scripts/release/` so you can
reproduce any step locally on a Mac.

### Signing tiers (chosen automatically by which secrets exist)

| Tier | Secrets present | Result | User experience |
|------|-----------------|--------|-----------------|
| **0 — ad-hoc** | none | Universal, `codesign -` | Must run `xattr -cr` once (matches upstream) |
| **1 — Developer ID** | `MACOS_CERT_*` | Signed + Hardened Runtime | Fewer Gatekeeper prompts; still quarantined |
| **2 — Notarized** | `MACOS_CERT_*` **+** `AC_API_*` | Signed + notarized + stapled | Launches clean, no `xattr` needed |

You don't edit the workflow to move between tiers — you just add secrets. Tier 0 works today.

### Secrets & variables

Set these under **Settings → Secrets and variables → Actions**.

**Optional app integrations** (baked into the build; dormant if absent):
- `DISCORD_CLIENT_ID` — enables Discord Rich Presence
- `SPOTIFY_CLIENT_ID` — enables the Spotify import flow

**Tier 1 — Developer ID signing** (requires a paid Apple Developer account, $99/yr):
- `MACOS_CERT_P12` — base64 of your *Developer ID Application* cert exported as `.p12`
  (`base64 -i cert.p12 | pbcopy`)
- `MACOS_CERT_PASSWORD` — the `.p12` export password
- `MACOS_KEYCHAIN_PASSWORD` — any throwaway string; secures the ephemeral CI keychain

**Tier 2 — Notarization** (App Store Connect API key, Developer role):
- `AC_API_KEY_ID` — the key's ID
- `AC_API_ISSUER_ID` — the issuer ID
- `AC_API_KEY_P8` — the full text of the `AuthKey_XXXX.p8` file

**Homebrew auto-bump** (optional):
- Variable `HOMEBREW_TAP_REPO` — e.g. `brianruggieri/homebrew-youtube-music-macos`
- Secret `HOMEBREW_TAP_TOKEN` — a PAT that can push to that tap

### Homebrew cask

`packaging/homebrew/youtube-music-macos.rb` is a ready-to-adapt cask. To distribute via Homebrew
under our own name (instead of upstream's `0xjemm/youtube-music-macos` tap):

1. Create a tap repo: `brianruggieri/homebrew-youtube-music-macos`.
2. Copy the template to `Casks/youtube-music-macos.rb` there.
3. Set `HOMEBREW_TAP_REPO` + `HOMEBREW_TAP_TOKEN`, then flesh out the `homebrew` job in
   `release.yml` (currently a documented stub) to `sed` the new `version`/`sha256` (from
   `SHA256SUMS.txt`) into the cask and open a PR. The stub is intentionally not wired to a live
   repo so it never fails for people who don't run a tap.

Until then, users can keep installing from upstream's tap, or grab the `.dmg`/`.zip` straight
from our Releases.

---

## Considerations & open questions

### Is this a commercial product? — No, and it shouldn't try to be.

This is an **MIT-licensed, unofficial WebKit wrapper** around a third-party website you don't
control. That's fine to publish for free, but several things make monetizing it a bad idea:

- **Trademark.** "YouTube Music", the name, and the logo are Google's. Using them to *describe*
  a free, clearly-unofficial client is defensible nominative use; putting them on a *paid*
  product invites a trademark/passing-off problem. The app and README already lean on YT's
  marks — keep the "unofficial" framing prominent.
- **YouTube Terms of Service.** YT's ToS restricts accessing the service through
  non-approved clients and restricts separating/altering the service. A free personal-use
  wrapper is the kind of thing that's widely tolerated; charging for access to Google's service
  through an unofficial client is materially riskier.
- **The audio tap & Spotify import.** The visualizer taps the app's own audio via a Core Audio
  process tap (needs TCC "Audio Recording" consent, prompted on first use). Spotify import uses
  the user's *own* Spotify app credentials via PKCE. Both are user-consented and local — fine
  for a free tool, but they're exactly the kind of capability that raises scrutiny if sold.
- **We inherited MIT.** We must keep the upstream copyright/license (`jem`) and the vendored
  Butterchurn/MilkDrop MIT notices. We can add our own copyright line, not remove theirs.

**Recommendation:** ship it free and open-source, keep "unofficial / not affiliated with Google"
visible, and don't gate features behind payment. If you ever wanted revenue, "donations /
GitHub Sponsors" is the safe lane; "paid app that resells access to YouTube Music" is not.

### Does anything need gating on signing / security / limitations?

Nothing needs to be *removed*, but a few things are **capability-gated by macOS**, and the
signing tier changes the user's install friction:

- **Audio-capture visualizer** — requires macOS **14.4+** and the user granting Audio Recording
  permission (the app already hides the mode below 14.4). The `NSAudioCaptureUsageDescription`
  string must stay in `Info.plist`. Notarization (Tier 2) matters most here: a notarized,
  Hardened-Runtime build is what lets the process-tap entitlement behave predictably under
  Gatekeeper.
- **Sandbox is intentionally off** (`com.apple.security.app-sandbox = false`). A sandboxed build
  couldn't do the audio process tap or the media-key/Now-Playing integration cleanly. That's the
  right call, but it means the **Mac App Store is not a distribution channel** — direct download
  + Homebrew is the only path. (App Store review would also reject a YouTube Music wrapper on
  trademark grounds anyway.)
- **Discord Rich Presence & Spotify import** are **build-time optional** — they no-op unless
  their client ID is baked in (`Secrets.swift`). Distributed builds are functional without them;
  add the secrets only if you want them live in official releases.
- **Auto-update:** there is **no Sparkle/updater** today. Users update via Homebrew or by
  re-downloading. Adding Sparkle later would *require* Tier 1+ signing (Sparkle verifies an
  EdDSA signature and, for the installer, a valid code signature) — another reason to stand up
  Developer ID signing before investing in auto-update.

---

## Files

| Path | Role |
|------|------|
| `.github/workflows/release.yml` | Tag-triggered build → sign → notarize → package → publish |
| `.github/workflows/build.yml` | Lean compile smoke test on PRs / manual |
| `scripts/release/make-secrets.sh` | Generate `Secrets.swift` (placeholders or real IDs) |
| `scripts/release/build-app.sh` | Universal Release build; ad-hoc or Developer ID |
| `scripts/release/notarize.sh` | `notarytool submit --wait` + `stapler staple` (no-op w/o creds) |
| `scripts/release/package.sh` | `.zip` + `.dmg` + `SHA256SUMS.txt` |
| `scripts/release/bump-version.sh` | Bump `MARKETING_VERSION`/build, optionally tag |
| `packaging/homebrew/youtube-music-macos.rb` | Cask template for your own tap |
