import AppKit
import SwiftUI
import WebKit

// User's theme choice. We don't recolor anything ourselves for this — forcing the
// WKWebView's NSAppearance flips its `prefers-color-scheme`, which the light-theme
// engine already follows (seed + `mq` change listener), so the whole existing
// pipeline reacts for free. `.system` (nil appearance) = today's behavior.
enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil   // inherit app / macOS appearance
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
    // Resolved darkness for the document-start seed; `.system` reads the live appearance.
    var isDark: Bool {
        switch self {
        case .light:  return false
        case .dark:   return true
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
    static var stored: ThemeMode {
        ThemeMode(rawValue: UserDefaults.standard.string(forKey: "themeMode") ?? "") ?? .system
    }
}

@Observable
@MainActor
class YouTubeMusicViewModel {
    weak var webView: WKWebView? {
        didSet { observeBackForward() }
    }

    // Mirror WKWebView's canGoBack/canGoForward into observable state so the header
    // buttons gray out correctly. KVO (not the navigation delegate) is load-bearing:
    // YT Music is an SPA, and its pushState route changes update the back-forward
    // list WITHOUT firing any navigation-delegate callback.
    var canGoBack = false
    var canGoForward = false
    private var backForwardObservations: [NSKeyValueObservation] = []

    private func observeBackForward() {
        guard let webView else { backForwardObservations = []; return }
        backForwardObservations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
        ]
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    // Force the webview's appearance to the chosen mode; the light-theme engine
    // picks up the resulting prefers-color-scheme change on its own. The app-wide
    // appearance must be forced too: WebKit draws the native root scrollbar from the
    // window's appearance (not the webview's), so without this the scroller follows
    // the macOS setting even when the theme is forced.
    func applyTheme(_ mode: ThemeMode) {
        NSApp.appearance = mode.appearance
        webView?.appearance = mode.appearance
    }

    // Background color of YT Music's nav bar, mirrored onto the native window
    // header so it tracks the web app's theme (dark / light / system). Defaults
    // to YT Music's dark header until the page reports its rendered color.
    var headerColor: NSColor = NSColor(srgbRed: 0.129, green: 0.129, blue: 0.129, alpha: 1.0)

    // Multiple consumers observe track changes (Now Playing, Discord). Use a list
    // instead of a single closure so registration order can't silently clobber
    // one observer with another.
    private var trackChangeObservers: [(String?, String?, URL?, Bool) -> Void] = []

    func addTrackChangeObserver(_ observer: @escaping (String?, String?, URL?, Bool) -> Void) {
        trackChangeObservers.append(observer)
    }

    func notifyTrackChange(title: String?, artist: String?, artworkUrl: URL?, isPlaying: Bool) {
        for observer in trackChangeObservers {
            observer(title, artist, artworkUrl, isPlaying)
        }
    }

    func playPause() {
        let js = "document.querySelector('#play-pause-button')?.click();"
        webView?.evaluateJavaScript(js)
    }

    func nextTrack() {
        let js = "document.querySelector('.next-button')?.click();"
        webView?.evaluateJavaScript(js)
    }

    func previousTrack() {
        let js = "document.querySelector('.previous-button')?.click();"
        webView?.evaluateJavaScript(js)
    }
}

// WKWebView runs the WebKit that ships with the *host* macOS — not "always the latest".
// On macOS 14 (our min target) the engine is Safari 17-era; macOS 15 is Safari 18-era.
// Advertising a Safari version newer than the real engine (e.g. Version/26 on Sonoma)
// makes YouTube Music ship a JS bundle the engine can't run. So derive the marketing
// version from the runtime OS major and report the *floor* Safari for that release: the
// real engine is always >= this, so YTM serves a bundle it can run while still avoiding
// the legacy/"unsupported browser" path an ancient UA would trigger.
enum SafariUA {
    static func marketingVersion(forMacOSMajor major: Int) -> String {
        switch major {
        case ...14: return "17.0"          // Sonoma (min supported): Safari 17-era WebKit
        case 15:    return "18.0"          // Sequoia: Safari 18-era
        default:    return "\(major).0"    // Tahoe (26)+: Safari version tracks the macOS major
        }
    }

    static var current: String {
        marketingVersion(forMacOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    // OS + AppleWebKit tokens are Apple-frozen and correct as-is; only Version/Safari track the release.
    static var userAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(current) Safari/605.1.15"
    }

    #if DEBUG
    static func selfCheck() {
        assert(marketingVersion(forMacOSMajor: 13) == "17.0", "selfCheck: <14 must floor to 17.0")
        assert(marketingVersion(forMacOSMajor: 14) == "17.0", "selfCheck: Sonoma → 17.0")
        assert(marketingVersion(forMacOSMajor: 15) == "18.0", "selfCheck: Sequoia → 18.0")
        assert(marketingVersion(forMacOSMajor: 26) == "26.0", "selfCheck: Tahoe → 26.0")
        assert(marketingVersion(forMacOSMajor: 27) == "27.0", "selfCheck: future majors track the OS")
        assert(userAgent.contains("Version/\(current) Safari/"), "selfCheck: UA must embed current version")
        print("[SafariUA] selfCheck PASSED (current=\(current))")
    }
    #endif
}

struct YouTubeMusicWebView: NSViewRepresentable {
    var viewModel: YouTubeMusicViewModel

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Pin the persistent (on-disk) data store explicitly. It's WebKit's default when
        // unset, but making it explicit is load-bearing: this store is what keeps the
        // YouTube sign-in cookies AND YT Music's service worker / Cache Storage across
        // launches. Never switch this to .nonPersistent() — that would silently sign the
        // user out and disable the offline cache. (WKWebView caching is governed by this
        // data store, NOT by URLCache, which has no effect on a WKWebView.)
        config.websiteDataStore = .default()
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Make WebView appear more like a real browser
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Enable the JS Fullscreen API (off by default in macOS WKWebView). Lets the
        // visualizer AND YT Music's own video player do true element fullscreen via
        // requestFullscreen(), instead of YT's degraded CSS fill-the-viewport fallback.
        config.preferences.isElementFullscreenEnabled = true

        // Inject scrollbar CSS at document start
        // Thumb colors are read from a CSS variable on <html>; the light-theme engine
        // sets data-ytm-mode (authoritative — driven by macOS appearance, set before
        // first paint and degraded-aware), so the scrollbars follow the SAME signal as
        // the rest of light mode. (The old data-ytm-theme luma-guess observer could leave
        // this unset → a near-white thumb invisible on the light page.) The light thumb is
        // a neutral medium grey at macOS-overlay weight so it actually reads on #f3f3f3.
        //
        // macOS-native overlay feel: narrow gutter (10px, ~7px visible thumb once inset),
        // fully transparent track, and a hover-only brightening so the thumb reads as
        // "dim at rest, lit on interaction" like AppKit's overlay scrollbars.
        // ponytail: true idle-timeout fade (thumb disappears entirely after N seconds of
        // no scroll/hover) needs a JS scroll listener + class toggle — WebKit's
        // ::-webkit-scrollbar pseudo-elements always reserve their gutter and can't do a
        // real overlay-over-content via CSS alone. This is the CSS-only approximation;
        // add the JS auto-hide only if QA finds the always-present thumb too distracting.
        let css = """
            html {
                --ytm-sb-thumb: rgba(255, 255, 255, 0.15);
                --ytm-sb-thumb-hover: rgba(255, 255, 255, 0.35);
            }
            html[data-ytm-mode="light"] {
                --ytm-sb-thumb: rgba(0, 0, 0, 0.32);
                --ytm-sb-thumb-hover: rgba(0, 0, 0, 0.5);
            }
            *, *::before, *::after {
                scrollbar-width: thin !important;
                scrollbar-color: var(--ytm-sb-thumb) transparent !important;
            }
            ::-webkit-scrollbar {
                width: 10px !important;
                height: 10px !important;
            }
            ::-webkit-scrollbar-track {
                background: transparent !important;
            }
            ::-webkit-scrollbar-thumb {
                background: var(--ytm-sb-thumb) !important;
                border-radius: 100px !important;
                border-right: 3px solid transparent !important;
                background-clip: padding-box !important;
                transition: background-color 150ms ease !important;
            }
            ::-webkit-scrollbar-thumb:hover {
                background: var(--ytm-sb-thumb-hover) !important;
                border-right: 3px solid transparent !important;
                background-clip: padding-box !important;
            }
            ::-webkit-scrollbar-corner {
                background: transparent !important;
            }
            /* Dark<->light theme crossfade (View Transitions API, driven by the light
               engine's switchMode). The UA default is a 250ms crossfade; a full-viewport
               theme fade reads better a touch slower — 400ms ease. Scoped to the engine's
               `ytm-theme-vt` marker class (added on <html> only around OUR transition) so we
               never restyle a view transition other page code might run; plays both ways. */
            html.ytm-theme-vt::view-transition-old(root),
            html.ytm-theme-vt::view-transition-new(root) {
                animation-duration: 400ms;
                animation-timing-function: ease;
            }
        """
        let cssJs = """
            (function() {
                var style = document.createElement('style');
                style.textContent = `\(css)`;
                document.documentElement.appendChild(style);
            })();
        """
        let cssScript = WKUserScript(source: cssJs, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(cssScript)

        // Ask for eviction-resistant ("persistent") storage so macOS doesn't purge YT
        // Music's service worker / Cache Storage under disk pressure. Idempotent and cheap;
        // safe to run every load. Supported in WKWebView since macOS 14 / Safari 17.
        let persistJs = "navigator.storage && navigator.storage.persist && navigator.storage.persist();"
        config.userContentController.addUserScript(
            WKUserScript(source: persistJs, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        // Warm TCP+TLS to the artwork/asset CDNs before playback needs them, via page-level
        // resource hints WebKit honors. The googlevideo (media) hosts are per-session and
        // can't be preconnected ahead of time, so this covers the stable image/font CDNs.
        // crossorigin must MATCH how each resource is actually fetched or the warmed socket
        // won't be reused: thumbnails load credentialed (plain <img> → no crossorigin);
        // fonts load as CORS (anonymous).
        let preconnectJs = """
            (function() {
                function hint(rel, href, cors) {
                    var l = document.createElement('link');
                    l.rel = rel; l.href = href;
                    if (cors) l.crossOrigin = 'anonymous';
                    (document.head || document.documentElement).appendChild(l);
                }
                ['https://lh3.googleusercontent.com', 'https://i.ytimg.com', 'https://yt3.ggpht.com']
                    .forEach(function(h) { hint('preconnect', h, false); hint('dns-prefetch', h, false); });
                hint('preconnect', 'https://fonts.gstatic.com', true);
                hint('dns-prefetch', 'https://fonts.gstatic.com', false);
            })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: preconnectJs, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        // Track info observer script
        let trackObserverJs = #"""
            (function() {
                let lastTitle = '';
                let lastPlayState = null;

                // Pick the largest artwork entry from a MediaMetadata.artwork list.
                function pickArtwork(md) {
                    if (!md || !md.artwork || !md.artwork.length) return '';
                    let best = md.artwork[0], bestArea = -1;
                    for (const a of md.artwork) {
                        // `sizes` may list several "WxH" tokens; score by the largest.
                        let area = 0;
                        for (const tok of (a.sizes || '').split(/\s+/)) {
                            const m = tok.match(/(\d+)x(\d+)/);
                            if (m) area = Math.max(area, parseInt(m[1], 10) * parseInt(m[2], 10));
                        }
                        if (area >= bestArea) { bestArea = area; best = a; }
                    }
                    let src = best.src || '';
                    // googleusercontent URLs carry a size suffix in one of two forms
                    // (=wN-hN-... or =sN-...); upscale whichever is present.
                    if (src) {
                        src = src.replace(/=w\d+-h\d+(-[^/]*)?$/, '=w544-h544-l90-rj')
                                 .replace(/=s\d+(-[^/]*)?$/, '=s544');
                    }
                    return src;
                }

                // Feed WebKit's own MediaSession->NowPlaying bridge the <video> clock, so
                // macOS Control Center / the notch show a live, scrubbable progress bar.
                // This populates navigator.mediaSession.setPositionState (which YT Music
                // doesn't reliably set itself) instead of standing up a competing native
                // MPNowPlayingInfoCenter publisher — so there's no double-owner conflict.
                function publishPosition() {
                    const ms = navigator.mediaSession;
                    const v = document.querySelector('video');
                    if (!ms || !ms.setPositionState || !v) return;
                    const dur = v.duration;
                    if (!isFinite(dur) || dur <= 0) return;
                    try {
                        ms.setPositionState({
                            duration: dur,
                            position: Math.min(Math.max(v.currentTime, 0), dur),
                            playbackRate: v.playbackRate || 1
                        });
                    } catch (e) { /* invalid state mid-transition — ignore */ }
                }

                function sendTrackInfo() {
                    // Read from the Media Session API, which YT Music populates. This
                    // is far more stable than scraping player-bar CSS classes.
                    const md = navigator.mediaSession && navigator.mediaSession.metadata;
                    const video = document.querySelector('video');

                    const title = md?.title?.trim() || '';
                    const artist = md?.artist?.trim() || '';
                    const artwork = pickArtwork(md);
                    const isPlaying = video ? !video.paused : false;

                    // Send track info when title changes
                    if (title && title !== lastTitle) {
                        lastTitle = title;
                        window.webkit.messageHandlers.trackInfo.postMessage({
                            title: title,
                            artist: artist,
                            artwork: artwork,
                            isPlaying: isPlaying
                        });
                    }

                    // Send play state when it changes
                    if (isPlaying !== lastPlayState) {
                        lastPlayState = isPlaying;
                        window.webkit.messageHandlers.trackInfo.postMessage({
                            title: title || lastTitle,
                            artist: artist,
                            artwork: artwork,
                            isPlaying: isPlaying
                        });
                    }
                }

                // Drive updates off the <video> element's own events. On a track
                // change / play / pause these fire within ~180-230ms (measured on
                // WebKit), vs up to 500ms waiting for the poll below, and they fire
                // ~0 times during steady playback — so this restores low-latency
                // metadata without the per-frame cost of a body MutationObserver.
                // Excluded on purpose: 'timeupdate' (fires ~4x/sec) and 'emptied'
                // (fires mid-transition while video.paused is briefly true, which
                // would emit a false "paused" flicker before 'play' lands ~100ms later).
                function hookVideo() {
                    const v = document.querySelector('video');
                    if (!v || v.__ytmHooked) return;
                    v.__ytmHooked = true;
                    ['loadedmetadata', 'play', 'pause', 'playing']
                        .forEach(e => v.addEventListener(e, () => { sendTrackInfo(); publishPosition(); }));
                }

                // Poll as a safety net: catches metadata that lands after the video
                // events (e.g. artist filled in late) and re-hooks if YT swaps the
                // <video> element. sendTrackInfo dedupes, so the extra calls are cheap.
                // Register a seek handler once so the OS scrubber / seek gestures actually
                // move playback — WebKit routes Control Center + media-key 'seekto' here.
                try {
                    navigator.mediaSession.setActionHandler('seekto', function(d) {
                        const v = document.querySelector('video');
                        if (!v) return;
                        if (d.fastSeek && 'fastSeek' in v) v.fastSeek(d.seekTime);
                        else v.currentTime = d.seekTime;
                        publishPosition();
                    });
                } catch (e) { /* seekto unsupported — Now Playing still shows a static bar */ }

                setInterval(function() { hookVideo(); sendTrackInfo(); publishPosition(); }, 500);
                hookVideo();
            })();
        """#
        let trackScript = WKUserScript(source: trackObserverJs, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(trackScript)
        config.userContentController.add(context.coordinator, name: "trackInfo")

        // Theme observer: read YT Music's actual rendered nav-bar background. Reading
        // the computed color (rather than a YT class name) resolves dark / light /
        // "system" uniformly, since the page has already applied the user's setting.
        let themeObserverJs = #"""
            (function() {
                let last = null;

                function pickBackground() {
                    // First non-transparent background, most-specific surface first.
                    for (const sel of ['ytmusic-nav-bar', 'ytmusic-app-layout', 'body', 'html']) {
                        const el = document.querySelector(sel);
                        if (!el) continue;
                        const bg = getComputedStyle(el).backgroundColor;
                        const m = bg.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/);
                        if (m && (m[4] === undefined || parseFloat(m[4]) > 0)) {
                            return { r: +m[1], g: +m[2], b: +m[3] };
                        }
                    }
                    return { r: 33, g: 33, b: 33 };
                }

                function update() {
                    const c = pickBackground();
                    const key = c.r + ',' + c.g + ',' + c.b;
                    if (key === last) return;
                    last = key;
                    // Rec. 709 luma; < 128 reads as a dark surface.
                    const isDark = (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) < 128;
                    document.documentElement.setAttribute('data-ytm-theme', isDark ? 'dark' : 'light');
                    window.webkit.messageHandlers.theme.postMessage(c);
                }

                setInterval(update, 1000);
                update();
            })();
        """#
        let themeScript = WKUserScript(source: themeObserverJs, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(themeScript)
        config.userContentController.add(context.coordinator, name: "theme")

        // Light-theme engine: learns YT Music's design tokens and derives a light
        // palette (see LightThemeEngine). Runs at document start so the override
        // <style> exists before first paint; gated on macOS appearance internally.
        // Seed the light-theme engine with the real system appearance at document
        // start — a WKWebView's prefers-color-scheme isn't reliably settled this early,
        // so without this the theme can miss light mode on load until a system toggle.
        let mode = ThemeMode.stored
        let isDark = mode.isDark
        let seedScript = WKUserScript(source: "window.__ytmNativeDark = \(isDark ? "true" : "false");",
                                      injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(seedScript)   // before the engine, so it reads the seed

        let lightScript = WKUserScript(source: LightThemeEngine.script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(lightScript)

        // Visualizer capability flag (document start, mirrors the __ytmNativeDark seed):
        // tells the page whether native audio capture (macOS 14.4+ process tap) is
        // available before it decides to offer the visualizer.
        let vizSeed = WKUserScript(source: "window.__ytmVizSupported = \(AudioTap.isSupported ? "true" : "false");",
                                   injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(vizSeed)

        // JS->native visualizer control: { action: "modeOn" | "modeOff" }.
        config.userContentController.add(context.coordinator, name: "visualizer")

        // Bootstrap loader: read each visualizer asset from the bundle and inject as a
        // WKUserScript (document-end, main frame). Mechanism proven by Spike B — string
        // injection is not gated by CSP script-src; blob-worklet loading wired in Task 6.
        let loadJS: (String, String?) -> String? = { name, subdir in
            (Bundle.main.url(forResource: name, withExtension: "js", subdirectory: subdir)
                ?? Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Resources/" + (subdir ?? ""))
                ?? Bundle.main.url(forResource: name, withExtension: "js"))
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        // Stream smoother MUST inject at document START (all other scripts are
        // document-end): its fetch hook has to see the first /youtubei/v1/player call
        // and its MediaSource/SourceBuffer prototype patches must precede YT's player
        // boot. See .claude/plans/seamless-mode-switch.md.
        if let smootherSrc = loadJS("stream-smoother", "visualizer") {
            config.userContentController.addUserScript(
                WKUserScript(source: smootherSrc, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        // Worklet source for visualizer.js. A worklet must load into the
        // AudioWorklet context (not the page), so we hand its source over as a
        // string and let visualizer.js build a blob: module from it. base64 +
        // atob keeps the injected literal free of quotes/newlines; JS source is
        // ASCII so it round-trips cleanly. Registered BEFORE visualizer.js below.
        if let workletSrc = loadJS("pcm-worklet", "visualizer") {
            let b64 = Data(workletSrc.utf8).base64EncodedString()
            config.userContentController.addUserScript(
                WKUserScript(source: "window.__pcmWorkletSource = atob('\(b64)');",
                             injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let vizScripts: [(String, String?)] = [
            ("fs-controls-util",       "visualizer"),
            ("butterchurn.min",        "visualizer"),
            ("butterchurnPresets.min", "visualizer"),
            ("preset-list",            "visualizer"),
            ("visualizer",             "visualizer"),
        ]
        for (name, subdir) in vizScripts {
            if let src = loadJS(name, subdir) {
                config.userContentController.addUserScript(
                    WKUserScript(source: src, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
        }

        #if DEBUG
        // Song<->Video toggle probe (debug builds, YTM_TOGGLE_PROBE=1 launches only).
        // Self-driving: navigates to a video-backed track, toggles Video->Song->Video,
        // logs media-element events + rAF frame gaps, and NSLogs the result via the
        // perfProbe handler. Measures the stream-swap hiccup inside the real app so it
        // can be compared against the plain-Chrome baseline.
        if ProcessInfo.processInfo.environment["YTM_TOGGLE_PROBE"] == "1" {
            config.userContentController.add(context.coordinator, name: "perfProbe")
            // A/B seed: the smoother reads __smootherFlags at document START, so the
            // all-off control seed must be installed before it. The probe enables the
            // flags mid-run (treatment phase) — bridge checks its flag per swap and
            // loudness lazy-installs on the first enabled swap, so runtime enable works.
            // Mutate-in-place when the smoother already created its flags object (user
            // scripts share addition order, and the smoother captures its own reference
            // — replacing the global would leave the smoother reading stale defaults).
            config.userContentController.addUserScript(WKUserScript(
                source: "(function(){var f=window.__smootherFlags;if(f){f.bridge=false;f.loudness=false;}else{window.__smootherFlags={bridge:false,loudness:false};}})();",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            config.userContentController.addUserScript(WKUserScript(source: #"""
            (function () {
                if (window.__probeInstalled) return; window.__probeInstalled = true;
                var log = [];
                function L(tag, extra) { var e = Object.assign({ t: +performance.now().toFixed(1), tag: tag }, extra || {}); log.push(e); }
                var EV = ['loadstart','loadedmetadata','canplay','seeking','seeked','waiting','stalled','playing','pause','play','emptied','durationchange'];
                function wire(v) { if (v.__pw) return; v.__pw = true; EV.forEach(function (ev) { v.addEventListener(ev, function () { L(ev, { ct: +v.currentTime.toFixed(3), rs: v.readyState }); }); }); }
                document.querySelectorAll('video').forEach(wire);
                new MutationObserver(function () { document.querySelectorAll('video').forEach(wire); }).observe(document.documentElement, { childList: true, subtree: true });
                var last = performance.now();
                (function loop() { var n = performance.now(); if (n - last > 100) L('FRAME_GAP', { gap: +(n - last).toFixed(0) }); last = n; requestAnimationFrame(loop); })();
                document.addEventListener('ytm-swapfade', function (e) { L('FADE_' + (e.detail && e.detail.phase), {}); });
                document.addEventListener('ytm-smoother', function (e) { L('SMOOTHER', e.detail); });
                // RMS trace from the native AudioTap feed (interleaved stereo Float32,
                // base64, ~60Hz batches). We own __milkFeed: the visualizer UI is never
                // activated in a probe run, only the native capture (modeOn).
                var rms = [];
                var pcm = [];      // {t, d: Float32Array} mono 6kHz batches, ~12s retained
                var pcmSamples = 0;
                window.__milkFeed = function (b64) {
                    try {
                        var bin = atob(b64), u8 = new Uint8Array(bin.length);
                        for (var i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
                        var f = new Float32Array(u8.buffer), s = 0;
                        for (var j = 0; j < f.length; j++) s += f[j] * f[j];
                        var now = performance.now();
                        rms.push({ t: Math.round(now), v: Math.sqrt(s / f.length) });
                        if (rms.length > 12000) rms.shift();
                        // Mono 6kHz downmix (stereo interleaved 48k -> stride 8 frames)
                        var frames = f.length >> 1, n = Math.floor(frames / 8);
                        var d = new Float32Array(n);
                        for (var k = 0; k < n; k++) { var idx = k * 16; d[k] = (f[idx] + f[idx + 1]) * 0.5; }
                        pcm.push({ t: now, d: d }); pcmSamples += n;
                        while (pcmSamples > 6000 * 12) { pcmSamples -= pcm[0].d.length; pcm.shift(); }
                    } catch (e) {}
                };
                // Flatten PCM in [t0,t1] (wall-clock ms) into one array at ~6kHz.
                function pcmWindow(t0, t1) {
                    var out = [];
                    for (var i = 0; i < pcm.length; i++) {
                        var b = pcm[i], durMs = b.d.length / 6;
                        if (b.t + durMs < t0 || b.t > t1) continue;
                        for (var k = 0; k < b.d.length; k++) {
                            var st = b.t + k / 6;
                            if (st >= t0 && st <= t1) out.push(b.d[k]);
                        }
                    }
                    return out;
                }
                // Does the tail of what played BEFORE the audible transition repeat
                // after it? Max normalized cross-correlation of A (last 400ms pre) vs
                // B (900ms post) over lags 0..700ms. Duplication = high corr at a lag.
                function dupMetric(tRelease) {
                    var A = pcmWindow(tRelease - 450, tRelease - 50);
                    var B = pcmWindow(tRelease, tRelease + 900);
                    if (A.length < 1200 || B.length < 3000) return { corr: -1, lagMs: -1, note: 'insufficient-pcm' };
                    var aN = 0; for (var i = 0; i < A.length; i++) aN += A[i] * A[i];
                    if (aN < 1e-6) return { corr: -1, lagMs: -1, note: 'silent-tail' };
                    var best = 0, bestLag = 0;
                    for (var L = 0; L + A.length <= B.length; L += 2) {
                        var dot = 0, bN = 0;
                        for (var j = 0; j < A.length; j++) { dot += A[j] * B[j + L]; bN += B[j + L] * B[j + L]; }
                        if (bN < 1e-6) continue;
                        var r = dot / Math.sqrt(aN * bN);
                        if (r > best) { best = r; bestLag = L; }
                    }
                    return { corr: +best.toFixed(3), lagMs: Math.round(bestLag / 6) };
                }
                function post(m) { try { webkit.messageHandlers.perfProbe.postMessage(m); } catch (e) {} }
                function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
                function v() { return document.querySelector('video'); }
                // Longest continuous sub-threshold run inside [t0,t1] (ms). Threshold is
                // reported raw alongside so the analysis can recalibrate offline.
                var TH = 0.003;
                function silentMs(t0, t1) {
                    var start = null, prev = null, longest = 0;
                    rms.forEach(function (p) {
                        if (p.t < t0 || p.t > t1) return;
                        if (p.v < TH) { if (start === null) start = p.t; prev = p.t; }
                        else if (start !== null) { longest = Math.max(longest, prev - start); start = null; }
                    });
                    if (start !== null) longest = Math.max(longest, prev - start);
                    return longest;
                }
                function btn(c) { return document.querySelector('.av-toggle button.' + c); }
                async function toggle(cls, label) {
                    var t0 = performance.now();
                    L('CLICK ' + label, { ct: +v().currentTime.toFixed(3) });
                    btn(cls).click();
                    await sleep(6000);
                    L('GAP ' + label, { silentMs: silentMs(t0, t0 + 3500), rmsPoints: rms.length });
                    // The audible transition is align-release when the hold ran, else handover.
                    var rel = null, hand = null;
                    for (var i = log.length - 1; i >= 0; i--) {
                        var e = log[i];
                        if (e.tag !== 'SMOOTHER' || e.t < t0) continue;
                        if (!rel && e.module === 'bridge' && e.event === 'align-release') rel = e;
                        if (!hand && e.module === 'swap' && e.event === 'handover') hand = e;
                    }
                    var tRel = rel ? rel.t : (hand ? hand.t : 0);
                    if (tRel) L('DUP ' + label, dupMetric(tRel));
                }
                // Position-matched pairs: same seek target + settle before control and
                // treatment so musical dynamics don't skew the RMS comparison.
                async function seekSettle(sec) { try { v().currentTime = sec; } catch (e) {} await sleep(2500); }
                async function run() {
                    post('probe installed on ' + location.pathname);
                    await sleep(8000);
                    if (!/watch/.test(location.pathname)) { post('navigating to watch page'); location.href = 'https://music.youtube.com/watch?v=i3Jv9fNPjgk'; return; }
                    for (var i = 0; i < 40 && !(v() && v().readyState >= 3 && !v().paused && v().currentTime > 2); i++) {
                        if (i === 5 && v() && v().paused) { var b = document.querySelector('ytmusic-player-bar #play-pause-button'); if (b) b.click(); }
                        await sleep(500);
                    }
                    if (!(v() && v().readyState >= 3 && !v().paused)) { post('FAIL: playback never started; log=' + JSON.stringify(log)); return; }
                    if (!btn('song-button') || !btn('video-button')) { post('FAIL: toggle not found'); return; }
                    // The native tap occasionally misses its first start (process-tap
                    // race right after launch) — retry until PCM actually flows.
                    for (var ta = 0; ta < 6 && !rms.length; ta++) {
                        try { webkit.messageHandlers.visualizer.postMessage({ action: 'modeOn' }); } catch (e) {}
                        await sleep(2500);
                        if (!rms.length) { try { webkit.messageHandlers.visualizer.postMessage({ action: 'modeOff' }); } catch (e) {} await sleep(800); }
                    }
                    if (!rms.length) L('RMS_UNAVAILABLE', {});
                    log.length = 0;
                    L('PHASE control', { flags: JSON.stringify(window.__smootherFlags) });
                    await seekSettle(60);
                    await toggle('song-button', 'ctrl-song');
                    await toggle('video-button', 'ctrl-video');
                    window.__smootherFlags.bridge = true;
                    window.__smootherFlags.loudness = true;
                    L('PHASE treatment', { flags: JSON.stringify(window.__smootherFlags) });
                    await seekSettle(60);
                    await toggle('song-button', 'treat-song');
                    await toggle('video-button', 'treat-video');
                    await toggle('song-button', 'treat2-song');
                    await toggle('video-button', 'treat2-video');
                    L('PHASE rapid', {});
                    var t0 = performance.now();
                    btn('song-button').click(); await sleep(150); btn('video-button').click();
                    await sleep(6000);
                    L('GAP rapid', { silentMs: silentMs(t0, t0 + 3000) });
                    try { webkit.messageHandlers.visualizer.postMessage({ action: 'modeOff' }); } catch (e) {}
                    post('RESULT ' + JSON.stringify(log));
                }
                run();
            })();
            """#, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        #endif

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // uiDelegate supplies the native file picker for <input type=file> (e.g. the
        // "Edit thumbnail" playlist-cover upload). Without it WKWebView silently drops
        // the open-panel request and the button does nothing.
        webView.uiDelegate = context.coordinator
        // Advertise the Safari version that matches the host OS's real WebKit engine
        // (see SafariUA) — a hard-coded Version/26 would lie to YouTube Music on the
        // macOS 14/15 systems we still support.
        webView.customUserAgent = SafariUA.userAgent
        // Native two-finger swipe to go back/forward, same as Safari.
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        // Debug-only: lets Safari's Develop menu attach to the WKWebView for DOM inspection.
        // Never enabled in Release so shipped builds aren't remotely inspectable.
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
        webView.appearance = mode.appearance   // force light/dark; nil = follow system
        NSApp.appearance = mode.appearance     // window too — native root scrollbar keys off it

        viewModel.webView = webView
        context.coordinator.webView = webView
        context.coordinator.installLifecycleObservers()

        if let url = URL(string: "https://music.youtube.com") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // Tear the feed down with the view: cancel the timer, stop the tap, and drop the
    // visualizer message handler so a discarded WebView can't leave a 60 Hz tap running.
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopVisualizerFeed()
        coordinator.removeLifecycleObservers()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "visualizer")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var viewModel: YouTubeMusicViewModel
        weak var webView: WKWebView?

        // Visualizer feed state. Both owned on the MainActor; the feed timer fires
        // on the main queue and bridges to them via MainActor.assumeIsolated.
        private var audioTap: AudioTap?
        private var feedTimer: DispatchSourceTimer?

        // Lifecycle gates for the 60 Hz feed. The TAP stays alive while mode is on;
        // only the timer is started/stopped as these flip, so a backgrounded or
        // paused visualizer does no per-frame work. updateCapture() recomputes
        // the single "should the timer run" condition rather than pause/resume the
        // DispatchSource directly (which would risk a suspend/resume imbalance crash).
        private var modeActive = false
        private var appActive = true
        private var windowMiniaturized = false
        private var trackPlaying = true

        // Tokens for the 4 AppKit lifecycle observers; removed in dismantleNSView.
        private var lifecycleObservers: [NSObjectProtocol] = []

        init(viewModel: YouTubeMusicViewModel) {
            self.viewModel = viewModel
            super.init()
        }

        // MARK: - Visualizer feed

        /// Start (or no-op if already running) the visualizer feed. Creates the tap,
        /// marks mode active, and lets updateCapture() decide whether the 60 Hz timer
        /// should actually run. Idempotent: a second modeOn while running returns early
        /// so we never stack a second tap.
        @MainActor func startVisualizerFeed(_ webView: WKWebView) {
            modeActive = true        // user intent; updateCapture starts the tap iff gates are open
            updateCapture()
        }

        /// Build (but do not resume) the ~60 Hz timer that pushes base64 stereo Float32
        /// PCM into the page via window.__milkFeed. Factored out so updateCapture can
        /// recreate it on resume without duplicating the event handler.
        @MainActor private func makeFeedTimer(_ webView: WKWebView) -> DispatchSourceTimer {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: .milliseconds(16))   // ~60 Hz
            t.setEventHandler { [weak self, weak webView] in
                // The timer fires on the main queue, so we are really on the MainActor.
                // assumeIsolated bridges this nonisolated @Sendable handler to the
                // MainActor-isolated audioTap and the MainActor evaluateJavaScript call
                // without a per-tick Task allocation (sound: queue is .main).
                MainActor.assumeIsolated {
                    guard let self, let webView, let tap = self.audioTap else { return }
                    // Drain ONLY the frames captured since the last tick (non-overlapping), so
                    // we feed the worklet ~real-time audio instead of a sliding window that
                    // floods + overflows its ring. Cap protects against a stalled tick; normal
                    // ticks yield ~800 frames (48 kHz / 60). Empty => nothing new, skip.
                    let pcm = tap.drainNew(maxFrames: 4096)               // interleaved stereo, fresh only
                    guard !pcm.isEmpty else { return }
                    let b64 = pcm.withUnsafeBufferPointer { ptr in
                        Data(bytes: ptr.baseAddress!, count: ptr.count * MemoryLayout<Float>.stride)
                            .base64EncodedString()
                    }
                    webView.evaluateJavaScript("window.__milkFeed && window.__milkFeed('\(b64)')")
                }
            }
            return t
        }

        /// Single source of truth for capture. The tap AND the 60Hz feed should run iff
        /// mode is on, the app is active, the window isn't miniaturized, and the track is
        /// playing. Starts the tap (and emits nativeStatus) + timer when they should run and
        /// are absent; STOPS the tap + timer when they shouldn't. So capture genuinely pauses
        /// on app-resign / miniaturize / track-pause (plan Global Constraint: "tap + render
        /// run only while active") — not just the feed — and "Try again" (modeOff->modeOn)
        /// can recreate a silent/denied tap.
        @MainActor private func updateCapture() {
            let shouldCapture = modeActive && appActive && !windowMiniaturized && trackPlaying
            guard let webView else { return }
            if shouldCapture {
                if audioTap == nil {
                    let tap = AudioTap()
                    do {
                        try tap.start()
                    } catch {
                        // A start() throw is a SETUP failure (no WebKit audio child yet,
                        // PID-translate miss, aggregate-device error) — NOT a TCC denial
                        // (denial surfaces as silent capture, not a throw). Report a generic,
                        // retryable error rather than wrongly sending the user to System
                        // Settings > Privacy for a non-permission problem.
                        webView.evaluateJavaScript("window.MilkViz && window.MilkViz.nativeStatus({state:'error',code:'audioUnavailable'})")
                        return
                    }
                    audioTap = tap
                    webView.evaluateJavaScript("window.MilkViz && window.MilkViz.nativeStatus({state:'ok'})")
                }
                if feedTimer == nil {
                    let t = makeFeedTimer(webView)
                    feedTimer = t
                    t.resume()
                    // Resume the page's rAF render loop too (it was paused when last gated off).
                    webView.evaluateJavaScript("window.MilkViz && window.MilkViz.resume()")
                }
            } else {
                let wasRunning = feedTimer != nil || audioTap != nil
                feedTimer?.cancel(); feedTimer = nil
                audioTap?.stop(); audioTap = nil
                // Stop the page's rAF render loop so a backgrounded/minimized/paused visualizer
                // does no per-frame work (the native tap+timer are already stopped above).
                if wasRunning { webView.evaluateJavaScript("window.MilkViz && window.MilkViz.pause()") }
            }
        }

        @MainActor func stopVisualizerFeed() {
            modeActive = false
            updateCapture()          // gates closed by modeActive=false -> stops tap + timer
        }

        /// Register the 4 AppKit lifecycle observers + the track play/pause observer.
        /// Each flips a gate and recomputes the feed timer. Called from makeNSView
        /// (MainActor). Notifications deliver on .main, so assumeIsolated is sound.
        @MainActor func installLifecycleObservers() {
            let nc = NotificationCenter.default
            func observe(_ name: Notification.Name, _ apply: @escaping @MainActor (Coordinator) -> Void) -> NSObjectProtocol {
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { guard let self else { return }; apply(self); self.updateCapture() }
                }
            }
            lifecycleObservers = [
                observe(NSApplication.didResignActiveNotification)   { $0.appActive = false },
                observe(NSApplication.didBecomeActiveNotification)   { $0.appActive = true },
                observe(NSWindow.didMiniaturizeNotification)         { $0.windowMiniaturized = true },
                observe(NSWindow.didDeminiaturizeNotification)       { $0.windowMiniaturized = false },
            ]
            // Track play/pause gates the feed too — paused audio is silence not worth feeding.
            viewModel.addTrackChangeObserver { [weak self] _, _, _, isPlaying in
                MainActor.assumeIsolated { guard let self else { return }; self.trackPlaying = isPlaying; self.updateCapture() }
            }
        }

        @MainActor func removeLifecycleObservers() {
            for token in lifecycleObservers { NotificationCenter.default.removeObserver(token) }
            lifecycleObservers = []
        }

        // MARK: - File uploads
        //
        // WKWebView has no built-in file picker — a page's <input type=file>.click()
        // is forwarded here, and if unhandled it's a no-op. YT Music's "Edit thumbnail"
        // (playlist cover upload) is the visible case: the button looked dead because
        // the open-panel request had nowhere to go. Bridge it to a native NSOpenPanel.
        func webView(_ webView: WKWebView,
                     runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                let cancelled = response != .OK
                completionHandler(cancelled ? nil : panel.urls)
                // Hand first-responder back to the web view so WebKit resumes dispatching
                // events to the page.
                webView.window?.makeFirstResponder(webView)
                // On Cancel, WKWebView is slow to deliver the <input type=file> `cancel`
                // event, so YT's editor overlay + dimming backdrop outlive the panel by a
                // few seconds. We already KNOW the user cancelled, so don't wait for that
                // event — tear the overlay down ourselves: close the image-editor dialog
                // (which drops its backdrop) and shut any backdrop left orphaned. Scoped to
                // the image editor so no other dialog is touched; only runs on Cancel, so a
                // real pick (which opens the crop dialog) is never closed.
                if cancelled {
                    webView.evaluateJavaScript("""
                    (function(){
                      document.querySelectorAll('tp-yt-paper-dialog').forEach(function(d){
                        if (d.querySelector && d.querySelector('yt-image-editor-renderer') && d.close) d.close();
                      });
                      document.querySelectorAll('tp-yt-iron-overlay-backdrop').forEach(function(b){
                        if (b.close) b.close(); else b.remove();
                      });
                    })();
                    """, completionHandler: nil)
                }
            }
            // Sheet (not a detached panel) so the window stays key and dismissal returns
            // control to it at once; fall back to a free panel if there's no window yet.
            if let window = webView.window {
                panel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                panel.begin(completionHandler: finish)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "trackInfo",
               let body = message.body as? [String: Any] {
                let title = body["title"] as? String
                let artist = body["artist"] as? String
                let artworkUrlString = body["artwork"] as? String
                let artworkUrl = artworkUrlString.flatMap { URL(string: $0) }
                let isPlaying = body["isPlaying"] as? Bool ?? false

                Task { @MainActor in
                    self.viewModel.notifyTrackChange(title: title, artist: artist, artworkUrl: artworkUrl, isPlaying: isPlaying)
                }
            } else if message.name == "theme",
                      let body = message.body as? [String: Any],
                      let r = body["r"] as? Int, let g = body["g"] as? Int, let b = body["b"] as? Int {
                // Clamp page-supplied channels to 0...255 before handing them to AppKit. The
                // page (music.youtube.com) is trusted, but a compromised/injected page must
                // not be able to push out-of-range components into NSColor / the native header.
                let cr = max(0, min(255, r)), cg = max(0, min(255, g)), cb = max(0, min(255, b))
                let color = NSColor(srgbRed: CGFloat(cr) / 255.0, green: CGFloat(cg) / 255.0, blue: CGFloat(cb) / 255.0, alpha: 1.0)
                Task { @MainActor in
                    self.viewModel.headerColor = color
                }
            }
            #if DEBUG
            if message.name == "perfProbe" {
                NSLog("PERFPROBE: %@", String(describing: message.body))
                return
            }
            #endif
            if message.name == "visualizer",
                      let body = message.body as? [String: Any],
                      let action = body["action"] as? String {
                // Only honor capture commands from a real YT Music page. This handler is
                // registered for EVERY page in the WebView, so without validating the sender
                // an allowed remote page (the accounts.google.com sign-in flow, youtube.com,
                // etc.) could post modeOn and start the native audio tap. Gate on the frame's
                // own security origin (trusted, not page-supplied body data).
                let host = message.frameInfo.securityOrigin.host
                guard host == "music.youtube.com" || host.hasSuffix(".music.youtube.com") else { return }
                // Hop to the MainActor (this handler is nonisolated) before touching
                // the MainActor-isolated feed lifecycle.
                Task { @MainActor in
                    switch action {
                    case "modeOn":  if let wv = self.webView { self.startVisualizerFeed(wv) }
                    case "modeOff": self.stopVisualizerFeed()
                    case "enterFullscreen":
                        // A real user gesture makes WebKit reject the visualizer's element
                        // requestFullscreen (TypeError). Re-issuing it from here via
                        // evaluateJavaScript runs it WITHOUT transient activation, which WebKit
                        // accepts — so the click bounces through native to actually go fullscreen.
                        self.webView?.evaluateJavaScript("window.MilkViz && MilkViz.enterFullscreen && MilkViz.enterFullscreen()")
                    default:        break
                    }
                }
            }
        }

        // MARK: - Navigation policy
        //
        // Host policy (in evaluation order):
        //   1. No host (about:blank, data:, file:)  → allow
        //   2. support.google.com / help.youtube.com → cancel + show import sheet
        //      (YT Music's "Transfer playlists" link lands here; intercept before the
        //       google.com allow-entry below would swallow it)
        //   3. Allowed suffixes (YTM core + Google auth/CDN)  → allow
        //   4. Everything else  → cancel + open in system browser
        //
        // Google auth domains (accounts.google.com etc.) are explicitly allowed so
        // login keeps working. When in doubt, allow — stranding the user is worse
        // than leaking one unexpected navigation into the WebView.
        //
        // A full-page navigation (reload of music.youtube.com, or an allowed cross-origin
        // nav like the sign-in flow) destroys the page that owns the visualizer WITHOUT it
        // getting to post modeOff. Tear down the tap + 60Hz feed here so capture and the
        // evaluateJavaScript loop don't keep running against the new/destroyed page. SPA
        // route changes within YT Music don't fire this, so the active visualizer survives
        // normal in-app navigation. Delivered on the main thread (assumeIsolated is sound).
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                if modeActive { stopVisualizerFeed() }
            }
        }

        // ponytail: permit-list; add entries if new Google auth subdomains appear
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // Hostless navigations: only allow about:blank. Reject file:/data:/etc.
            // so an allowed page or redirect can't render local-file or arbitrary
            // data content inside this unsandboxed WebView.
            guard let host = url.host else {
                if url.scheme == "about" {
                    decisionHandler(.allow)
                } else {
                    decisionHandler(.cancel)
                }
                return
            }

            // Only http/https proceed (and only http/https ever reach NSWorkspace.open
            // below). Never launch an arbitrary custom-scheme handler app from an
            // in-webview navigation — real browsers prompt for that; we just refuse.
            guard url.scheme == "http" || url.scheme == "https" else {
                decisionHandler(.cancel)
                return
            }

            // Transfer-playlists dead-end → import sheet.
            // support.google.com / help.youtube.com are checked here BEFORE the
            // google.com allow-entry below would pass them through.
            // Only the specific "Transfer playlists from other apps" article is
            // intercepted; we require "transfer" AND a YTM context marker
            // ("youtubemusic" or "musicpremium") so that unrelated YT Music Premium
            // help pages (which contain "musicpremium" but no "transfer") fall through
            // to the system browser instead of opening the importer.
            // ponytail: heuristic on help-article path — update if Google moves the article
            if host == "support.google.com" || host == "help.youtube.com" {
                let raw = url.absoluteString.lowercased()
                if raw.contains("transfer") && (raw.contains("youtubemusic") || raw.contains("musicpremium")) {
                    decisionHandler(.cancel)
                    Task { @MainActor in ImportLauncher.shared.isPresented = true }
                } else {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                }
                return
            }

            let allowedSuffixes = [
                "music.youtube.com",
                "youtube.com",
                "googlevideo.com",
                "google.com",           // bare google.com + www/myaccount for OAuth redirect chain
                "accounts.google.com",
                "googleapis.com",
                "gstatic.com",
                "googleusercontent.com",
                "ggpht.com",
                "ytimg.com",
            ]
            for suffix in allowedSuffixes where host == suffix || host.hasSuffix(".\(suffix)") {
                decisionHandler(.allow)
                return
            }

            // Genuine off-site link → system browser
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

