# WebView → Native Offload Investigation (July 2026)

> **Scope.** A fan-out investigation into opportunities to offload mechanisms and
> functionality from the `WKWebView` (`https://music.youtube.com`) to native Swift /
> newer WebKit mechanisms, using bleeding-edge mid-2026 (macOS 26 "Tahoe" / Safari 26)
> APIs where they help — plus a dedicated study of **WKWebView native caching and
> optimal behavior**.
>
> **Method.** Five parallel investigations, each combining a read of this codebase with
> web research of current (July 8 2026) WebKit/Apple APIs. Every recommendation below is
> framed honestly: several headline ideas were investigated and **rejected** because the
> current approach is already near-optimal or the native path is a net risk. Those
> rejections are documented so they aren't re-proposed.
>
> **Deployment floor.** App targets macOS 14 (Sonoma); the visualizer's Core Audio tap
> already gates to macOS 14.4+. macOS-26-only APIs are flagged as future / min-OS-gated.

---

## Executive summary

The app is a lean WKWebView wrapper that has **already** offloaded the hard things to
native: the visualizer (Core Audio process tap), theme forcing (`NSAppearance`), window
chrome, Spotify import, Discord RPC, and all crypto (CryptoKit). What remains in the web
view is mostly there *for good reason* — but there is a short list of genuinely
high-leverage, low-risk wins, and a longer list of "investigated and rejected" ideas.

### The standout finding

**The app advertises Safari 17 while running the real Safari 26 engine.** The custom
user agent (`YouTubeMusicWebView.swift:376`) hard-codes `Version/17.0`, but WKWebView on
a mid-2026 Mac *is* WebKit 26. YouTube's desktop web app does UA-gated bundle selection,
so claiming Safari 17 likely makes YouTube ship a **legacy / polyfilled JS bundle** the
engine doesn't need — pure parse/compile/execute waste — and can trigger "unsupported
browser" nags. Reporting the truthful `Version/26.0` is a **one-line change** with near-zero
compatibility risk. This is the single best performance-per-effort item in the whole study.

### Top actionable wins (ranked by impact ÷ effort ÷ risk)

| Rank | Change | Area | Impact | Effort | Risk |
|:---:|--------|------|:------:|:------:|:----:|
| 1 | **Bump spoofed UA `Version/17.0` → real `26.0`** (ideally derive from WebKit bundle) so YouTube serves its modern bundle | §5 Bundle | **High** | Trivial | Very low |
| 2 | **Make persistent `WKWebsiteDataStore` explicit** (+comment on why) so a future "storage cleanup" can't silently kill login & YT's service worker | §1 Caching | Med | Trivial | None |
| 3 | **Inject `navigator.storage.persist()`** so YT Music's service worker / Cache Storage is eviction-resistant | §1 Caching | Med | Trivial | Very low |
| 4 | **Inject `setPositionState` + `seekto`** so WebKit's *existing* Now Playing bridge exposes a scrubbable Control Center timeline | §2 Media | Med (only real UX gap) | Low | Very low |
| 5 | **Visualizer IPC diet**: cached `callAsyncJavaScript(arguments:)` + `Uint8Array.fromBase64()` + encode off the MainActor | §4 Visualizer | Med-High | Low | Low |
| 6 | **Preconnect / dns-prefetch** the CDN + streaming hosts | §1/§5 | Low-Med | Low | Low |
| 7 | **Early process pre-warm**: build the WebView + start `load()` in `applicationDidFinishLaunching` | §5 Startup | Med | Low-Med | Low |
| 8 | **Visualizer worklet bypass**: feed Butterchurn's `updateAudio()` directly, delete the AudioWorklet + AudioContext + 64K ring | §4 Visualizer | Med-High | Med | Med (spike-verify) |
| 9 | **Split static theme CSS** off the JS `build()` rebuild path into a precompiled document-start sheet | §3 Theme | Med (CPU/cleanliness) | Low-Med | Low |
| 10 | Delete (or wire up) the dead `playPause/next/previous` DOM-click methods | §2 Media | Low (hygiene) | Trivial | None |

### Investigated and rejected (do **not** pursue — recorded to prevent re-litigation)

- **Sizing a `URLCache` to control the web cache** — a **no-op**. WKWebView caching is
  governed by `WKWebsiteDataStore` + WebKit's network/SW caches + Google's HTTP headers,
  not Foundation's `URLCache`. (§1)
- **Native `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` takeover of Now Playing** —
  WebKit's automatic MediaSession bridge already owns this correctly; a native publisher
  fights an un-disableable one (double-publisher flicker). Only the scrub-bar gap is worth
  closing, via injected JS (#4). (§2)
- **`WKContentRuleList` for the light theme** — content rules can only `block` or
  `display:none`; they **cannot set a color or any CSS property**. The engine sets no
  `display:none`, so it maps to nothing. (§3)
- **`WKURLSchemeHandler` to cache Google artwork/JS** — WebKit won't let an `https://`
  page load a custom scheme, and you can't rewrite YouTube's own URLs. Not viable. (§1)
- **`_WKUserStyleSheet` / `_setColorSchemePreference:` SPI** — private, App-Store-risky,
  and redundant with the supported `NSAppearance` + `WKUserScript` paths already used. (§3)
- **WebGPU for the visualizer** — shipped in Safari 26 but **not enabled in WKWebView**
  and no app-level flag exists mid-2026; also the visualizer isn't GPU-raster-bound. (§4)
- **Speculation Rules / prerender** — YT Music is an SPA (client-side routing), so there
  are almost no document navigations to accelerate; also off-by-default in Safari 26.2. (§5)
- **SwiftUI `WebView`/`WebPage`** — a clarity migration, not a perf win, and requires a
  macOS 26 min-target bump (drops Sonoma/Sequoia users). Future only. (§5)
- **Native Metal/`libprojectM` visualizer** — highest ceiling but a large project + a new
  native dependency; defer unless power profiling proves the in-page WebGL path is a real
  battery problem. (§4)

---

## 1. WKWebView Native Caching — Current State & Optimal Behavior

### 1.1 Current state (what the code does today)

The app creates a bare `WKWebViewConfiguration` and never touches any storage/cache surface. Every caching-relevant setting is therefore a WebKit default:

- **No `WKWebsiteDataStore` is set.** `YouTubeMusicWebView.makeNSView` builds `let config = WKWebViewConfiguration()` (`YouTubeMusicWebView.swift:94`) and configures only JS, media, user scripts, and message handlers. Because `config.websiteDataStore` is left untouched, the view uses `WKWebsiteDataStore.default()` — the **persistent, on-disk** store. This is the correct choice, but it is implicit.
- **No `URLCache` is configured** anywhere, and (see §1.2) that is fine because it would not affect the WKWebView anyway.
- **No `WKURLSchemeHandler`** is registered — the app loads `https://music.youtube.com` directly (`YouTubeMusicWebView.swift:390-392`) and lets WebKit's own network process do all fetching/caching.
- **Login/session persistence is entirely delegated to the default persistent store.** `YTMusicAuth.snapshot()` reads cookies straight from it: `await webView.configuration.websiteDataStore.httpCookieStore.allCookies()` (`YTMusic/YTMusicAuth.swift:19`). Because the store is persistent, the YouTube sign-in cookies (`__Secure-3PAPISID`, `SAPISID`, etc.) already survive relaunch — the login *is* sticky today, purely by default.
- **The InnerTube and Spotify clients bypass WKWebView entirely.** `YTMusicClient` and `SpotifyClient` use `URLSession.shared` with manually-attached cookie/auth headers (`YTMusic/YTMusicClient.swift:26,100-111`; `Spotify/SpotifyClient.swift:5,91`). These are ordinary `URLSession` requests (POSTs / bearer GETs) that are effectively uncacheable and unrelated to the WebView cache.
- **Artwork is *not* fetched or cached natively.** There is **no `MPNowPlayingInfoCenter`/`MediaPlayer` code in the project at all** (confirmed by grep). The Control Center "Now Playing" artwork is populated by **WebKit's own Media Session integration** — WebKit fetches the `navigator.mediaSession.metadata.artwork` URL inside its media/network process and caches it there, not in app code. The JS only *selects and upscales* the URL (`YouTubeMusicWebView.swift:186-207`, rewriting googleusercontent to `=w544-h544`). Discord RPC merely forwards the **URL string** to the Discord client, which fetches it itself (`DiscordRPC.swift:104-113`, `ContentView.swift:86-97`). So there is currently no native artwork download to cache.

Net: the app relies on WebKit defaults for everything, and those defaults are mostly right. The gaps are (a) nothing is *explicit/documented*, so a future "let's clean up storage" change could silently break the login and YT Music's service worker; and (b) a couple of cheap, low-risk wins (preconnect warm-up, persistent-storage request) are unused.

### 1.2 What actually controls WKWebView caching (the `URLCache` myth)

**`URLCache` does not control WKWebView content caching.** A very common misconception is that setting `URLCache.shared` (or a per-config `URLCache`) sizes the WebView's HTTP cache. It does not. WKWebView runs its networking in a **separate Networking process**, and its HTTP disk/memory cache, cookies, Cache Storage, IndexedDB, and Local Storage are all managed by the **`WKWebsiteDataStore`** attached to the configuration — a mechanism entirely separate from Foundation's `URLCache`. `NSURLCache` is technically present in the lower networking layer but gives very little control, and even less when used by a WKWebView; you cannot reliably steer WebKit's page/resource cache through `URLCache` the way you can for a plain `URLSession`. ([Apple Developer Forums — WKWebView configuration/URLCache](https://developer.apple.com/forums/thread/125224))

What *does* govern WKWebView caching:

1. **The server's HTTP cache headers.** `Cache-Control`, `ETag`, `Expires`, `Age` on responses from `music.youtube.com`, `*.ytimg.com`, `*.googleusercontent.com`, `*.googlevideo.com` decide what WebKit's network cache keeps and revalidates. You do not control these (they're Google's), and there is **no public API to set the size** of WebKit's network-process HTTP cache — it is managed automatically under the storage-quota policy below.
2. **Persistent vs. non-persistent `WKWebsiteDataStore`.** The single biggest lever you *do* control. `.default()` writes cookies, the HTTP cache, Cache Storage, and IndexedDB to disk (persist across launches). `WKWebsiteDataStore.nonPersistent()` keeps everything in memory and **writes nothing to disk** — that is "private browsing," and it also **disables Service Workers and the Cache API**. ([WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore), [nonPersistent()](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/1532934-nonpersistent))
3. **The per-origin storage quota / eviction policy.** Since Safari 17 / macOS 14 Sonoma, a **non-browser WKWebView app** gets an origin quota of **up to ~15% of total disk** (a *browser* app gets up to ~60%); the Storage Standard is fully supported, so an origin can call `navigator.storage.persist()` to opt into eviction-resistant "persistent" mode. ([Updates to Storage Policy — WebKit](https://webkit.org/blog/14403/updates-to-storage-policy/))
4. **Service Worker + Cache Storage (WebKit's real offline cache).** YT Music ships a service worker; on **macOS WKWebView with the default persistent store, service workers and their Cache Storage are supported and persisted** (they require a persistent data store — unavailable in non-persistent/private mode). On iOS the feature is additionally gated behind App-Bound Domains; **on macOS that gating does not apply**. ([Workers at Your Service — WebKit](https://webkit.org/blog/8090/workers-at-your-service/); [Service Workers in WKWebView](https://dev.to/ben/will-ios-14-support-service-workers-in-wkwebview-5gn))
5. **In-memory back/forward cache (bfcache) + WebProcessCache.** WebKit keeps the previous page as a suspended, fully-live snapshot (JS heap intact) and keeps warm WebProcesses for reuse — this is what makes YT Music's SPA navigation feel instant. Controlled by WebKit, not you; note a **full-page `reload()` destroys it** — relevant because the import flow calls `webViewModel.webView?.reload()` on finish (`ContentView.swift:53`), the one place the app deliberately blows the page cache away (acceptable, it's rare). ([Disabling WebKit's process caches — Matt Jacobson](https://mjacobson.net/blog/2024-01-WebKit-cache.html))

**Bottom line:** the "cache" for this app is the `WKWebsiteDataStore` + WebKit's network/SW caches, all fed by Google's own HTTP headers. You optimize by choosing the store correctly, not evicting it, requesting persistence, and warming connections — *not* by sizing a `URLCache`.

### 1.3 Recommended configuration for this app

#### A. Make the persistent data store explicit (correctness insurance)

Today the persistent store is used only by omission. Make it explicit so nobody "cleans up" into `nonPersistent()` and silently kills login + YT Music's service worker/offline cache.

```swift
// Option 1 — explicit default (zero behavior change, just self-documenting):
config.websiteDataStore = .default()

// Option 2 — a named persistent store (macOS 14+): isolates this app's web data
// and gives a clean, total-reset primitive. Data lives in its own on-disk partition
// keyed by a stable UUID. Only CUSTOM persistent stores have an identifier.
if #available(macOS 14.0, *) {
    let id = UUID(uuidString: "…stable, app-constant UUID…")!
    config.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
}
```

`WKWebsiteDataStore(forIdentifier:)` / `removeDataStore(forIdentifier:)` are **macOS 14.0+**. A named store is fully persistent and isolated on disk. Some clients adopt one specifically to dodge historical *default-store* session-cookie bugs ([WebKit bug 185624](https://bugs.webkit.org/show_bug.cgi?id=185624)). **Caveat:** migrating to a named store means existing users' default-store cookies don't carry over — they'd sign in once more. If login stickiness is the priority and there's one WebView, **Option 1 is the safe pick**; adopt Option 2 only if you want per-profile reset. ([Building Profiles with new WebKit API](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/))

**Do not set a `URLCache` on the config expecting it to help** — it won't (§1.2).

#### B. Keep the login session sticky (already works — protect it)

No code needed for the happy path: persistent store ⇒ cookies persist ⇒ `YTMusicAuth` keeps reading a valid `__Secure-3PAPISID`. Defensive rules: (1) never switch to `nonPersistent()`, (2) never blanket-call `removeData(ofTypes:…)` across `.cookies`, (3) if you add "sign out / reset," scope it to `removeDataStore(forIdentifier:)` or a targeted `httpCookieStore` delete rather than nuking everything.

#### C. Request persistent (eviction-resistant) storage — cheap durability win

So macOS doesn't evict YT Music's service worker / Cache Storage under disk pressure (idempotent, safe every load):

```swift
let persistJS = "navigator.storage && navigator.storage.persist && navigator.storage.persist();"
config.userContentController.addUserScript(
    WKUserScript(source: persistJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
```

`navigator.storage.persist()` is fully supported in WKWebView since macOS 14 / Safari 17. ([Updates to Storage Policy](https://webkit.org/blog/14403/updates-to-storage-policy/))

#### D. Warm the network path — cut first-play latency

- **Process warm-up:** the WKWebView is created and `load()`ed in `makeNSView`, which spins up the Web/Network processes. Moving that earlier (see §5.3) makes it overlap scene setup.
- **Preconnect/DNS-prefetch the heavy hosts** via a document-start script so TCP+TLS to the CDNs is ready before playback:

```swift
let preconnect = """
(function(){
  var hosts = ['https://lh3.googleusercontent.com','https://i.ytimg.com','https://fonts.gstatic.com'];
  hosts.forEach(function(h){
    ['preconnect','dns-prefetch'].forEach(function(rel){
      var l=document.createElement('link'); l.rel=rel; l.href=h; l.crossOrigin='anonymous';
      document.head && document.head.appendChild(l);
    });
  });
})();
"""
config.userContentController.addUserScript(
    WKUserScript(source: preconnect, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
```

`<link rel=preconnect>`/`dns-prefetch` are honored by WebKit on macOS (broadened in Safari 26). `googlevideo` hostnames are per-session/unpredictable, so streaming preconnect is best-effort. Avoid the private `_preconnectToServer:` SPI — the `rel=preconnect` route is the supported equivalent. ([WebKit Features in Safari 26.0](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/))

#### E. `WKURLSchemeHandler` for artwork/asset caching — **not viable here**

WebKit refuses to let an `https://` page load a custom-scheme resource, and you can't register a handler for `https` itself ([WebKit bug 138169](https://bugs.webkit.org/show_bug.cgi?id=138169)). Since the app loads Google's own pages referencing `https://…googleusercontent.com` / `…ytimg.com` URLs you cannot rewrite, a scheme handler can't intercept them. Making it work would need App-Store-risky SPI and still miss page-constructed URLs. **Do not pursue.** ([Custom scheme as secure — alastair.is](https://alastair.is/getting-wkwebview-to-treat-a-wkurlschemehandler-as-secure/))

#### F. Native artwork cache — a real but currently-*unused* opportunity

Nothing to cache today because the app never downloads artwork natively (WebKit fetches Now Playing art; Discord fetches its own). The opportunity **only materializes if a native `MPNowPlayingInfoCenter`/`MPMediaItemArtwork` path is added** (see §2). Then the correct pattern is a small native downloader backed by `NSCache` + a bounded on-disk directory keyed by the normalized googleusercontent URL — and **here a real `URLCache` *does* apply**, because it's your own `URLSession`:

```swift
// Only relevant IF native Now Playing artwork is added later.
let cache = URLCache(memoryCapacity: 16<<20, diskCapacity: 128<<20, directory: artURL)
let cfg = URLSessionConfiguration.default
cfg.urlCache = cache
cfg.requestCachePolicy = .returnCacheDataElseLoad
let artSession = URLSession(configuration: cfg)  // =w544-h544 suffix → immutable, ~100% hit rate
```

The `=w544-h544-l90-rj` suffix the JS already appends makes each art URL content-addressed and effectively immutable, so hit-rate would be near-100%. **Latent, not actionable** until a native media path exists.

### 1.4 Prioritized opportunities

| # | Opportunity | Impact | Effort | Risk | Recommendation |
|---|-------------|--------|--------|------|----------------|
| 1 | Make persistent `WKWebsiteDataStore` explicit + comment | Med | Trivial | None | **Do now** |
| 2 | `navigator.storage.persist()` injection | Med | Trivial | Very low | **Do now** |
| 3 | Preconnect / dns-prefetch injection | Low-Med | Low | Low | Do soon |
| 4 | Named persistent store (isolation + reset + dodges cookie bug) | Low-Med | Low | Med (**re-login on migration**) | Optional |
| 5 | Native artwork `URLSession`+`URLCache`+`NSCache` | Med — **only if** native media path added | Med | Low | Deferred |
| 6 | `WKURLSchemeHandler` to cache Google art/JS | — | High | High | **Don't** |
| 7 | Set a `URLCache` to "size the web cache" | None | — | — | **Don't — no-op myth** |

### 1.5 API availability (July 2026)

- `WKWebsiteDataStore.default()`/`.nonPersistent()` — all versions. **Stable.**
- `WKWebsiteDataStore(forIdentifier:)` — **macOS 14.0+.** Stable.
- `navigator.storage.persist()` / quota policy — **macOS 14 / Safari 17+.** Stable.
- Service Workers + Cache API — macOS with the **persistent** store. Stable.
- `rel=dns-prefetch`/`preconnect` — macOS since Safari 5; broadened in **Safari 26**. Stable.
- **No public `prewarmConnection` API** — warm the process by early instantiation (§5.3).
- Reviewed Safari 26.0–26.5 feature posts: caching deltas are incremental — **nothing changes the guidance above.**

---

## 2. Media Metadata, Now Playing & Media Keys — Native Offload

### 2.1 Current state

The app ships **zero** native media-session code. A repo-wide grep for `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`, `MediaPlayer` returns nothing. Everything in Control Center / the menu-bar Now Playing tile / the notch, plus hardware media-key handling, works **entirely because WebKit auto-bridges the page's `navigator.mediaSession` to the system MediaRemote daemon**. This is invisible, free, and already correct.

What the app *does* have is a JS scraper and an unused DOM-click API:

- **`trackObserverJs`** — `YouTubeMusicWebView.swift:181-265`. Reads `navigator.mediaSession.metadata` + the `<video>` paused flag, dedupes, posts `{title, artist, artwork, isPlaying}` over the `trackInfo` handler. Driven by `<video>` events (~180-230 ms) **plus a 500 ms poll** (`:262`). Artwork URL upscaled to 544×544 (`:202-205`).
- **Consumers of that metadata:** (a) **Discord Rich Presence** (`ContentView.swift:85-98` → `DiscordRPC.swift:104-143`) — the *only* real metadata consumer; and (b) the **visualizer play/pause gate** (`:544-546`).
- **DOM-click transport** — `viewModel.playPause()/nextTrack()/previousTrack()` (`:74-87`) `evaluateJavaScript` a `querySelector(...).click()`. **These three methods are defined but never invoked** — vestigial scaffolding. Media keys today do **not** go through them; they go straight into WebKit's bridge and the page's `mediaSession` action handlers.

**Critical framing:** the 500 ms poll and the `trackInfo` pipeline feed **Discord + the visualizer**, *not* Now Playing. Now Playing metadata/artwork/media keys are read by WebKit directly from `navigator.mediaSession` — already event-driven, not subject to the 500 ms latency. Any "500 ms polling" critique applies to Discord presence, not Control Center.

### 2.2 Honest analysis — is native offload a win?

**Mostly no, with one genuine gap.** This is the case where the automatic WebKit bridge is already near-optimal and a native takeover is a net risk:

1. **WebKit already routes remote commands to the page and publishes metadata + artwork to MediaRemote.** `MediaSessionManagerCocoa` connects MediaSession with MediaRemote/NowPlaying, routing remote commands to `navigator.mediaSession` and passing its metadata to NowPlaying, using `positionState` when present ([WebKit changeset 272445](https://trac.webkit.org/changeset/272445/webkit)). YT Music registers `play/pause/previoustrack/nexttrack`, so media keys, Control Center buttons, AirPods gestures, and the Touch Bar already work. Native buys nothing here.
2. **The one real gap is a scrubbable timeline / elapsed position.** WebKit only exposes a draggable Control Center progress bar when the page calls `navigator.mediaSession.setPositionState({duration, position, playbackRate})` and registers a `seekto` handler ([MDN: MediaSession](https://developer.mozilla.org/en-US/docs/Web/API/MediaSession)). YT Music's `setPositionState` support is experimental/inconsistent, so the tile usually shows **no live progress bar** — the only user-visible deficiency vs. a first-class native player.
3. **A full native takeover carries a double-publisher hazard.** `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` are **process-wide singletons**. If the host app publishes now-playing info while WebKit's WebContent process *also* publishes the page's, MediaRemote sees two sources from one app → last-writer-wins flicker, artwork/title races, mis-routed keys. There is **no clean public API to disable WebKit's bridge**, so "go native" means fighting a publisher you can't turn off.
4. **Media-key latency/correctness is already good.** Native `MPRemoteCommandCenter` isn't more reliable than WebKit's routing for this page — the fragile path is the DOM-click one (breaks if YT renames `#play-pause-button`), which isn't even in the media-key path today.

**Verdict:** Do **not** do a wholesale native takeover. WebKit's bridge is the right owner. The only worthwhile improvement is closing the scrubbable-position gap — lowest-risk by **augmenting the page's own MediaSession from injected JS**, so WebKit's existing bridge exposes the timeline.

### 2.3 Recommendation

**Primary (recommended): inject `setPositionState` + a `seekto` handler in JS** — no native MediaPlayer code, no double-registration. Fold into `trackObserverJs`:

```js
// Feeds WebKit's own MediaSession→NowPlaying bridge, so Control Center / the notch
// get a scrubbable timeline WITHOUT any native MPNowPlayingInfoCenter.
function publishPosition() {
  const v = document.querySelector('video');
  const ms = navigator.mediaSession;
  if (!v || !ms || !isFinite(v.duration) || v.duration <= 0) return;
  try {
    ms.setPositionState({ duration: v.duration,
      position: Math.min(v.currentTime, v.duration), playbackRate: v.playbackRate || 1 });
  } catch (_) {}
}
try {
  navigator.mediaSession.setActionHandler('seekto', (d) => {
    const v = document.querySelector('video'); if (!v) return;
    if (d.fastSeek && 'fastSeek' in v) v.fastSeek(d.seekTime); else v.currentTime = d.seekTime;
    publishPosition();
  });
} catch (_) {}
// Call publishPosition() on the existing play/pause/loadedmetadata hooks and once
// per ~1s while playing (only when document.visibilityState === 'visible').
```

Impact: real Control Center scrub bar + AirPods/keyboard seek, using the already-authoritative metadata source. Risk: near-zero.

**Secondary (optional, not recommended):** a native `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` layer — only if you deliberately want to *own* Now Playing (decouple from page DOM, survive full-page navs). It requires new inputs the pipeline doesn't carry (elapsed/duration), widening `notifyTrackChange` (which touches Discord + visualizer observers), and an artwork byte-fetch to build `MPMediaItemArtwork` — all on top of the double-publisher risk. Skip unless a concrete requirement forces it.

**Cleanup regardless:** the unused `playPause/next/previous` methods (`:74-87`) are dead code — either wire them to the secondary path or delete them; they imply a media-key mechanism that doesn't exist.

### 2.4 Prioritized opportunities

| # | Opportunity | Impact | Effort | Risk |
|---|-------------|--------|--------|------|
| 1 | JS `setPositionState` + `seekto` → Control Center scrub bar via WebKit's bridge | High (only real gap) | Low | Very low |
| 2 | Delete/wire up dead `playPause/next/previous` methods | Low (hygiene) | Trivial | None |
| 3 | Add elapsed/duration to `trackInfo` → accurate Discord `timestamps.end` | Low-Med | Low | Low |
| 4 | Full native `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` takeover | Med (only if decoupling is a goal) | High | **High** (double-publisher) |
| 5 | Native `MPMediaItemArtwork` byte-fetch (only needed by #4) | Low | Med | Low |

### 2.5 Sources

[WebKit changeset 272445](https://trac.webkit.org/changeset/272445/webkit) · [MDN: MediaSession](https://developer.mozilla.org/en-US/docs/Web/API/MediaSession) · [W3C Media Session](https://www.w3.org/TR/mediasession/) · [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) · [MPRemoteCommandCenter forum #685333](https://developer.apple.com/forums/thread/685333) · [macOS 26 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes) (no relevant MediaPlayer changes). MediaPlayer framework macOS 10.12.2+; MediaSession bridge macOS 11.4+.

---

## 3. Light-Theme Engine — Offload & Efficiency Opportunities

> Respects DESIGN.md's settled analysis: theming lag beyond content render is **~0 ms**;
> YT's ~500 ms cold-nav is content load, not us. Findings below are **CPU / cleanliness /
> robustness** wins, not latency wins.

### 3.1 Current state — what the engine costs

`music.youtube.com` ships no light theme, so `LightThemeEngine.swift` injects one ~1,290-line JS blob as a single document-start `WKUserScript` (`YouTubeMusicWebView.swift:322-323`). It runs three workloads, only one of which is a "theme engine" in the derivation sense:

| Workload | Location | What it does per run | Cost character |
|---|---|---|---|
| **Palette derivation** (`scan`→`build`) | `LightThemeEngine.swift:577-718` | Walks `document.styleSheets`→`cssRules`, harvests `--yt*/--paper*/--iron*` tokens + light-grey literals, inverts lightness (`:117`), regenerates one `<style id=ytm-light-theme>` | CSSOM read; gated by a grew-guard (`:683`) so rebuild skips when nothing new appeared |
| **Static rule emission** | `build()` `:700-704` re-emitting `SURFACE_FIXES` (`:181-315`), `ENHANCE` (`:323-464`), `RED` (`:470-500`), `FOCUS` (`:507-528`) | On **every rebuild** re-runs `scope()` (`:559-569`) over ~60 hardcoded selector→declaration pairs and re-concatenates | Pure CPU/string work; **inputs are 100% static** yet recomputed inside the dynamic rebuild |
| **Runtime contrast audit** | `audit()` `:855-995`, `collectText()` `:757`, `auditSurfaces()` `:818` | `querySelectorAll('*')` + shadow-root recursion, `getComputedStyle` per node, WCAG math, in-place fixes | The ~34 ms/11k-node walk (`DESIGN.md:218`); already adaptively backed off to every 6th tick once stable |
| **Inline pins** | `pin*` `:1065-1190` | Re-assert light values YT overwrites inline (immersive header, nav-bar, menu, tokens, logo) | Cheap; must be runtime (chases page-content-driven values) |

The scrollbar/view-transition CSS (`YouTubeMusicWebView.swift:124-178`) is a **second** static stylesheet, also injected by wrapping raw CSS in a JS `createElement('style')`.

### 3.2 What CAN move to a native/declarative mechanism — and what cannot

**`WKContentRuleList` is a dead end for theming.** Compiled content-rule lists support exactly: `block`, `block-cookies`, `css-display-none`, `make-https`, `ignore-previous-rules`, `notify` ([WebKit — Content Blockers](https://webkit.org/blog/3476/content-blockers-first-look/)). Critically, `css-display-none` can **only** apply `display:none` — no color, background, border, custom property, or `!important`. The engine's entire job is *assigning color/CSS-property values*, which content rules cannot express; and it never sets `display:none`, so the one capability they offer matches **zero** current behavior. **Record it as evaluated-and-rejected** so it isn't re-proposed.

**What genuinely can move off the JS hot path:** the **static CSS** — the ~60 `SURFACE_FIXES`/`ENHANCE`/`RED`/`FOCUS` rules plus the scrollbar/view-transition sheets. Literal selectors + literal colors; nothing depends on `scan()`'s runtime output. Today they are `scope()`-transformed and re-concatenated on every `build()` rebuild (`:700-704`) and coupled into the same `<style>` as the derived tokens. They can be **precompiled once and injected as a separate document-start stylesheet**.

**What must stay in JS (irreducible):** `scan()`/`invert()` token derivation (reads YT's *runtime* CSS — the self-healing point), `audit()`/`auditSurfaces()` (measures *rendered* contrast — no declarative API measures contrast), and all `pin*` functions (chase inline/WAAPI values that outrank stylesheet `!important`).

### 3.3 Native user-stylesheet & color-scheme APIs — supported vs SPI

| Mechanism | Status | Verdict |
|---|---|---|
| `WKUserScript` injecting a `<style>` (current) | **Public, supported**, 10.10+ | The correct home for static CSS. Keep. |
| `_WKUserStyleSheet` + `_addUserStyleSheet:` | **SPI / private** | Injects a real user-origin sheet page JS can't see/scan, but **underscore SPI → App Store rejection risk**. Only if shipping outside MAS. Not default. |
| `_setColorSchemePreference:` (force `prefers-color-scheme`) | **SPI / private** | **Not needed** — app already forces it the supported way via `NSAppearance` (`:49-52`, `383-384`). Skip. |
| Declarative CSS custom-property / color injection | **Does not exist (mid-2026)** | No supported API to inject CSS variables/properties declaratively. `WKUserScript`+`<style>` remains the only supported path. |

### 3.4 Recommendations (CPU / robustness)

- **R1 — Split static CSS into its own precompiled document-start sheet (primary win).** Move `SURFACE_FIXES`/`ENHANCE`/`RED`/`FOCUS` out of `build()`; do the `scope()` prefixing once (build-time in Swift or once in JS) and ship as a constant. Removes ~60 `scope()` calls + a 60-rule concat from *every* rebuild, guarantees the static layer exists before first paint independent of `scan()`, and cleanly separates "static theme" from "derived palette." Supported, no SPI. `build()` then emits only the derived `<style id=ytm-light-theme>`.
- **R2 — Consolidate the three static sheets** (scrollbar + view-transition + R1) into one document-start `<style>`. Micro-cleanliness.
- **R3 — Do NOT adopt `WKContentRuleList`.** Record the rejection (cannot set colors; hides only).
- **R4 — Do NOT adopt `_setColorSchemePreference:` SPI.** Redundant with the supported `NSAppearance` path.
- **R5 (not recommended).** A baseline inverted-token sheet refined by `scan()` — marginal early-frame win but hardcodes YT's ~15 primitives, fighting the self-healing design; `PIN_TOKENS` already pins the criticals inline at document-start.

### 3.5 Prioritized opportunities

| # | Opportunity | Impact | Effort | Risk | Type |
|---|---|---|---|---|---|
| R1 | Split static CSS → precompiled document-start sheet; drop from `build()` loop | Med (removes ~60 `scope()`+concat/rebuild) | Low-Med | Low | CPU + robustness |
| R2 | Consolidate scrollbar + view-transition + static theme into one sheet | Low | Low | Low | Cleanliness |
| R3 | Formally reject `WKContentRuleList` in DESIGN.md | Low (prevents wasted work) | Trivial | None | Docs |
| R4 | Reject `_setColorSchemePreference:` SPI | Low | Trivial | None | Docs |
| R5 | Precompiled baseline token sheet refined by `scan()` | Low, uncertain | Med | Med (fights self-healing) | Not recommended |
| — | Incremental `MutationObserver`-scoped audit (already noted `DESIGN.md:238`) | Med CPU under heavy scroll | High | Med | CPU only — pursue only if profiled |

### 3.6 Sources & risk flags

[WKContentRuleList](https://developer.apple.com/documentation/webkit/wkcontentrulelist) · [Content Blockers](https://webkit.org/blog/3476/content-blockers-first-look/) · [css-display-none is hide-only — forum #734182](https://developer.apple.com/forums/thread/734182) · [WKUserScript](https://developer.apple.com/documentation/webkit/wkuserscript). **⚠️ `_WKUserStyleSheet` / `_setColorSchemePreference:` are private SPI — App Store risk; not recommended.** No supported declarative CSS-injection API exists mid-2026; `WKUserScript`+`<style>` is the mechanism. Only R1/R2 are worthwhile — the color-deriving core, contrast audit, and inline pins are irreducibly JS.

---

## 4. Audio Visualizer Pipeline — IPC & Render Offload

### 4.1 Current state

Four-stage chain: Core Audio process tap → 60 Hz main-thread timer that base64-encodes stereo PCM → `evaluateJavaScript("window.__milkFeed('<b64>')")` → JS `atob` → AudioWorklet → Butterchurn (WebGL2 MilkDrop) render.

- **Native drain + encode + push:** `YouTubeMusicWebView.swift:452-476` (`makeFeedTimer`); base64 + `evaluateJavaScript` at **`:466-472`**, on `queue: .main` (`:453`) via `MainActor.assumeIsolated` (`:460`).
- **Ring drain:** `AudioTap.swift:65-76`, `drainNew(maxFrames:)` at `:252-254`.
- **JS receive → worklet:** `Resources/visualizer/visualizer.js:77-87` — `atob` → `Uint8Array.from(…, c=>c.charCodeAt(0))` → `Float32Array` → `port.postMessage(arr, [buf])`.
- **Worklet ring + deinterleave:** `Resources/visualizer/pcm-worklet.js` (64K ring, per-sample copy).
- **Lifecycle gating (good):** `updateCapture()` `:485-520` already stops the tap, timer, *and* the page's rAF loop on resign/miniaturize/pause — per-frame cost is only paid while visible + playing.

### 4.2 Cost characterization

At 48 kHz stereo, each ~16 ms tick drains ≈800 frames = **6.4 KB** → base64 **≈8.5 KB of JS source string**, 60×/s ≈ **510 KB/s** across the UI→WebContent IPC boundary. The audio is copied/transformed **~7 times** end to end. Specific inefficiencies:

1. **Encode runs on the MainActor** 60×/s (`:468-471`), competing with YT's UI.
2. **`evaluateJavaScript` recompiles a fresh ~8.5 KB script every tick** (`:472`) — no cached callable.
3. **The JS decode is the slowest form:** `Uint8Array.from(atob(b64), c=>c.charCodeAt(0))` runs a per-byte callback ≈**510K/s**, plus two intermediate allocations.
4. **Redundant buffering:** Butterchurn needs only ~1024 time-domain samples per rendered frame and computes its **own** FFT (`jberg/butterchurn` `audioProcessor.js`: `getByteTimeDomainData`, `updateAudio(...)`). The current design streams *every* sample through a whole `AudioContext` + worklet + zero-gain sink + `AnalyserNode` that then re-samples.

Not catastrophic (gated + 510 KB/s is modest), but it burns main-thread cycles on encode + JS-parse + a 510K/s decode callback that a better channel or lighter sink would erase.

### 4.3 Binding constraint: no zero-copy native→JS binary channel (mid-2026)

- **`evaluateJavaScript`/`callAsyncJavaScript` accept only strings / JSON-serializable values** — no `NSData`/`ArrayBuffer`/typed-array. An `NSArray` of `NSNumber` would be *worse* than base64. **base64-in-a-string is near the practical floor for native→JS.**
- **JS→native message bodies share the JSON-only limit** — an `ArrayBuffer` posted to a handler isn't delivered as bytes. Even a pull model (`WKScriptMessageHandlerWithReply`, macOS 11+) returns base64/JSON.
- **`SharedArrayBuffer` is unusable** — requires COOP+COEP cross-origin isolation on the *top document* (`music.youtube.com`), which we don't control.

**Implication:** you can't make the *bytes* cheaper while Butterchurn stays in-page. In-page wins are (i) fewer/lighter crossings, (ii) a lighter JS sink, (iii) encode off the main thread. To eliminate base64/IPC entirely you must leave the page (option b).

### 4.4 Ranked options

**(a) Cheaper IPC, keep WebGL-in-page — recommended, low effort, ~50-70% of per-tick cost removed.** Stackable:
- **a1. Delete the AudioWorklet; inject via Butterchurn's `viz.audio.updateAudio(t, tL, tR)`.** Removes the `AudioContext`, 64K worklet ring, transfer `postMessage`, and deinterleave loop; native then sends only ~1024 samples/frame. *Spike-verify* `render()` uses the injected buffers when `connectAudio` was never called.
- **a2. Replace string-interpolated `evaluateJavaScript` with cached `callAsyncJavaScript(arguments:)`** so WebKit stops recompiling ~8.5 KB/tick; swap the decode to a tight loop or feature-detect **`Uint8Array.fromBase64()`** (TC39, Safari 26) to drop the 510K/s callback entirely.
- **a3. Move encode off the MainActor** (the ring is already thread-safe) and/or invert to a **pull model** driven by the page rAF via `WKScriptMessageHandlerWithReply` — one crossing per drawn frame, display-synced, and drop the `DispatchSourceTimer`.
- **a4. Move Butterchurn into a Worker via `OffscreenCanvas`** — keeps WebGL2 render + decode off YT's main thread. Biggest contention win short of going native; most plumbing churn.

**(b) Fully native Metal render overlay — highest ceiling, high effort, defer.** Reuse `AudioTap`, FFT via **Accelerate/vDSP**, render MilkDrop in **Metal** to a `CAMetalLayer`/`MTKView` composited over the WKWebView (the app already sets `drawsBackground=false`, `:377`), driven by `CVDisplayLink` and gated like `updateCapture()`. The hard part is the renderer: Butterchurn presets are runtime-compiled MilkDrop scripts — not reusable in JavaScriptCore (no GPU context). Realistic route is **libprojectM** (C++ MilkDrop engine, Metal backend) — a **new native dependency** (v1 plan forbade new native deps) + preset-compat validation + z-order/fullscreen/overlay-tracking work. Zero IPC/base64/in-page GPU, native vsync/ProMotion/HDR, lowest power.

**(c) WebGPU upgrade — not viable in WKWebView; monitor.** WebGPU shipped on-by-default in Safari 26 but is **NOT enabled in WKWebView and has no app-level flag** ([forum #770862](https://developer.apple.com/forums/thread/770862)). Even if available, Butterchurn isn't raster-bound at windowed sizes, so payoff is small. **Blocked.**

### 4.5 Recommendation

Do **(a)**, not (b)/(c), unless power profiling proves the in-page path is a real battery problem:
1. **a2 first (an afternoon):** cached `callAsyncJavaScript` + `Uint8Array.fromBase64()` w/ tight-loop fallback + encode off MainActor. Pure win, no architectural change.
2. **a1 next (spike + a day):** prove `updateAudio()` direct injection renders, then delete `pcm-worklet.js` + `AudioContext` + sink and shrink payload to ~1024 samples/frame.
3. **a4 if Web Inspector shows main-thread contention.**
4. Keep the excellent `updateCapture()` gating (`:485-520`) — already the biggest power lever.

Treat **(b)** as a separate "native visualizer" project justified only by measured power/thermal wins; if pursued: `libprojectM` + vDSP + `CVDisplayLink`-driven Metal overlay.

### 4.6 Prioritized opportunities

| # | Opportunity | Impact | Effort | Risk | Notes |
|---|-------------|--------|--------|------|-------|
| a2 | Cached `callAsyncJavaScript(arguments:)` + `Uint8Array.fromBase64()`/tight-loop; encode off MainActor | Med-High | Low | Low | `fromBase64` = Safari 26+; keep atob fallback |
| a1 | Bypass worklet: Butterchurn `updateAudio()`; send ~1024 samples/frame | Med-High | Med | Med | **Spike-verify** render path |
| a3 | Pull model via `WKScriptMessageHandlerWithReply` on rAF; drop 60 Hz timer | Med | Med | Low | Still base64 (no binary bridge) |
| a4 | Butterchurn → Worker + `OffscreenCanvas` | Med | Med-High | Med | Verify OffscreenCanvas+WebGL2 min version |
| b | Native `libprojectM` + vDSP → Metal overlay, `CVDisplayLink`-gated | High | High | High | New native dep; violates v1 "no new native deps" |
| c | WebGPU backend | Low (not raster-bound) | — | Blocked | **No WKWebView support mid-2026** |

### 4.7 Sources

[WebGPU in Safari 26](https://webkit.org/blog/16993/news-from-wwdc25-web-technology-coming-this-fall-in-safari-26-beta/) · [WebGPU not in WKWebView — forum #770862](https://developer.apple.com/forums/thread/770862) · [COOP/COEP](https://web.dev/articles/coop-coep) · [callAsyncJavaScript args are JSON-typed](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:in:completionhandler:)) · [Butterchurn](https://github.com/jberg/butterchurn) (`updateAudio`, internal FFT) · [Metal + WKWebView overlay — forum #45852](https://developer.apple.com/forums/thread/45852). Whole feature stays within the existing macOS 14.4+ tap gate except (c).

---

## 5. Bleeding-Edge 2026 WebKit & Platform Performance Opportunities

### 5.1 Current state

- **UA spoofed to Safari 17**, hard-coded (`YouTubeMusicWebView.swift:376`): `…Version/17.0 Safari/605.1.15`.
- **Bare, unshared config** (`:94`); `processPool`, `websiteDataStore`, memory knobs untouched.
- **No process pre-warming** — the WebView is built + first-loaded in `makeNSView` (`:370`, `:391`), which SwiftUI calls only when `ContentView` first renders, *after* app/window/scene bring-up. Process spin-up does **not** overlap the network fetch.
- **Single WindowGroup / single WebView** — process-pool sharing not applicable.
- **Target macOS 14** — the gate on macOS-26-only APIs.
- **App crypto is already native** (`Spotify/PKCE.swift`, `YTMusic/SAPISIDHash.swift` — CryptoKit). Nothing crypto-shaped left in JS to offload.

### 5.2 User-agent vs. served bundle (highest-value item)

The spoofed string is byte-for-byte the real Safari 26 UA **except one token.** The genuine Safari 26 UA is `…Version/26.0 Safari/605.1.15`. Apple **froze** the OS token (`Mac OS X 10_15_7`) and engine token (`AppleWebKit/605.1.15`) years ago — they're correct even on Tahoe, so the app's choice of those is right. The **only** divergence is `Version/17.0` vs the real `Version/26.0`. ([Niels Leenheer — Safari 26 UA](https://nielsleenheer.com/articles/2025/the-user-agent-string-of-safari-on-ios-26-and-macos-26/), [51Degrees — Apple froze the UA](https://51degrees.com/blog/apple-ios26-safari26-user-agent-string-device-detection))

**Why claiming Safari 17 is counter-productive:** the WKWebView runs the real WebKit 26 engine, but YT's desktop app does UA-gated bundle selection *in addition to* feature detection — the reported `Version/NN` picks a polyfill/transpile tier and drives "update your browser" nags. Serving a "Safari 17" client makes YT ship **down-leveled JS + polyfills the engine doesn't need** — pure parse/compile/exec waste. ([Smashing — smart bundling](https://www.smashingmagazine.com/2018/10/smart-bundling-legacy-code-browsers/))

**Recommendation — report the real WebKit version.** Only `Version/NN.N` differs, so it's one line with ~zero risk (you're telling YT the truth about the engine it's talking to):

```swift
webView.customUserAgent =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
  "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"
```

Better: **derive it** so it never goes stale — map the installed WebKit framework's version to the Safari marketing version (validate the mapping):

```swift
let webkitVersion = Bundle(identifier: "com.apple.WebKit")?
    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
```

### 5.3 Startup / cold-launch-to-first-paint

**Pre-warm by building the WebView + starting the load as early as possible.** No public `prewarmConnection` on macOS, but the standard technique is to instantiate the WKWebView and kick its first navigation *before* it's on screen, so process spawn + first-byte overlap SwiftUI/window bring-up ([WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper), [NSHipster — WKWebView](https://nshipster.com/wkwebview/)). Today that starts only in `makeNSView`.

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let warmWebView: WKWebView = {
        let wv = WKWebView(frame: .zero, configuration: makeYTMConfiguration())
        wv.load(URLRequest(url: URL(string: "https://music.youtube.com")!))
        return wv
    }()
    func applicationDidFinishLaunching(_ n: Notification) { _ = Self.warmWebView }
}
```

`makeNSView` returns `AppDelegate.warmWebView` instead of building a fresh one. **Preserve the theme-seed ordering** — the `ThemeMode.stored` / `__ytmNativeDark` document-start seed must still run before that early load. `WKProcessPool` sharing is **not applicable** (single WebView).

### 5.4 Navigation hinting (Speculation Rules) — not recommended now

Speculation Rules (prerender/prefetch) is **shipped disabled-by-default in Safari 26.2** and behind a flag. More fundamentally, YT Music is an **SPA** — in-app navigation is client-side routing, not document navigations, so there's almost nothing to prerender. Revisit only if WebKit enables it by default, and only for the initial cross-origin auth hop. ([WebKit — Safari 26.2](https://webkit.org/blog/17640/webkit-features-for-safari-26-2/))

### 5.5 Memory

- macOS auto-suspends occluded WebContent processes, but this app **keeps audio playing when minimized/backgrounded** (by design — see the `updateCapture` gates), so the content process legitimately can't fully suspend while a track plays. The realistic win is small and bounded by the audio requirement.
- **`obscuredContentInsets`** (new in WebKit 26) is for content under browser chrome; this app's 32 px `WindowHeader` sits *above* the WebView in a `VStack` (`ContentView.swift:28-31`), not overlapping — **not applicable.**
- No reliable public "cap this WebView's memory" API. Hygiene is already good (single WebView, teardown in `dismantleNSView`).

### 5.6 JavaScriptCore / JIT / WASM / JSPI

- YT's bundle isn't ours to change beyond the UA lever; JIT/WASM tiering is already modern on the real engine.
- **JSPI is not default in Safari 26** (beta in the Safari 27 line / WWDC26). No app action.
- App-logic-in-JS-vs-native is already resolved right (native CryptoKit); nothing to move.

### 5.7 SwiftUI `WebView` / `WebPage` (future, min-OS-gated)

WWDC25 shipped a first-class SwiftUI `WebView` + observable `WebPage` (`callJavaScript`, observable `title`/`url`/`estimatedProgress`, `WebPage.NavigationDeciding`) — cleaner than the current `NSViewRepresentable` + coordinator + KVO. **But it requires macOS 26 as the deployment target**, dropping Sonoma/Sequoia users, and it's a code-clarity migration, **not** a runtime-perf win. Low priority / future. ([WebKit for SwiftUI](https://developer.apple.com/documentation/webkit/webkit-for-swiftui), [WWDC25 session 231](https://developer.apple.com/videos/play/wwdc2025/231/))

### 5.8 Prioritized opportunities

| # | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|
| 1 | **Bump spoofed UA `Version/17.0` → real `26.0`** (or derive) | **High** | Very low | Very low | Stable (Safari 26 GA Sept 2025) |
| 2 | **Pre-warm: build WebView + `load()` in `applicationDidFinishLaunching`** | Med | Low-Med | Low (preserve theme-seed order) | Stable, all macOS |
| 3 | Derive UA `Version` from installed WebKit so it never goes stale | Med (durability of #1) | Low | Low | Stable |
| 4 | Reduce memory when minimized | Low (bounded by audio) | Med | Med | Mostly automatic |
| 5 | Speculation Rules prerender/prefetch | Very low (SPA) | Med | Med | **Beta/flagged** (off in 26.2) |
| 6 | Migrate to SwiftUI `WebView`/`WebPage` | None on perf | High | High (drops macOS 14-15) | Needs **macOS 26** target |
| 7 | JSPI / WASM offload | None (crypto already native) | — | — | Not default until Safari 27 |

**Bottom line:** #1 (stop advertising Safari 17) is the one high-leverage, near-free change; #2 (early pre-warm) is next, standard practice, no new-OS dependency. Everything else is inapplicable to a single-WebView SPA wrapper, already handled, or gated behind a macOS 26 bump / still-beta flags.

### 5.9 Sources

[Safari 26.0 features](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/) · [Safari 26.2 (Speculation Rules, flagged)](https://webkit.org/blog/17640/webkit-features-for-safari-26-2/) · [WWDC26/Safari 27 (JSPI)](https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/) · [WebKit for SwiftUI](https://developer.apple.com/documentation/webkit/webkit-for-swiftui) · [Niels Leenheer — Safari 26 UA](https://nielsleenheer.com/articles/2025/the-user-agent-string-of-safari-on-ios-26-and-macos-26/) · [WKProcessPool](https://developer.apple.com/documentation/webkit/wkprocesspool) · [WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper).

---

## Cross-cutting notes & suggested sequencing

1. **A "quick wins" batch** (all trivial-to-low, low-risk, no architectural change) makes a
   natural first PR: UA `Version/26.0` (§5 #1), explicit persistent datastore + comment
   (§1 #1), `storage.persist()` injection (§1 #2), `setPositionState`+`seekto` injection
   (§2 #1), preconnect hints (§1 #3), and deleting the dead transport methods (§2 #2).
   Each is independently shippable and independently revertable.
2. **Visualizer a2** (§4) is a self-contained second PR — measurable per-tick CPU win with
   a `Uint8Array.fromBase64()` feature-detect and a tight-loop fallback.
3. **Everything requiring a spike or a min-OS bump** (visualizer a1/a4, native Metal
   renderer, SwiftUI `WebView`, named datastore migration) should be its own scoped effort
   with the verification path called out — especially the visualizer worklet-bypass, which
   must be spike-verified against Butterchurn's render path before committing.
4. **Respect the settled DESIGN.md analysis.** None of the theme findings chase the
   ~500 ms cold-nav (that's YT content load); they're CPU/robustness only.

## How to verify any change

Per DESIGN.md, changes are validated from the outside in the WebKit engine users run:

```bash
cd harness && nvm use && npm test        # all screens × both themes
npm test -- --project=light              # light only (text-contrast failures fail the build)
npm run report                           # screenshots + diffs + contrast logs
```

Theme/CSS changes must keep the light audit green and stay within the three sanctioned red
contexts. Visualizer, caching, and media changes need runtime verification in a Release
build (the tap requires macOS 14.4+ and Audio Capture permission).
