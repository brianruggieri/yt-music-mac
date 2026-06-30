import AppKit
import SwiftUI
import WebKit

@Observable
@MainActor
class YouTubeMusicViewModel {
    weak var webView: WKWebView?

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

struct YouTubeMusicWebView: NSViewRepresentable {
    var viewModel: YouTubeMusicViewModel

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
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
        // Thumb colors are read from a CSS variable on <html>; the theme observer
        // script flips data-ytm-theme so the scrollbars follow YT Music's light/dark.
        let css = """
            html {
                --ytm-sb-thumb: rgba(255, 255, 255, 0.15);
                --ytm-sb-thumb-hover: rgba(255, 255, 255, 0.25);
            }
            html[data-ytm-theme="light"] {
                --ytm-sb-thumb: rgba(0, 0, 0, 0.18);
                --ytm-sb-thumb-hover: rgba(0, 0, 0, 0.30);
            }
            *, *::before, *::after {
                scrollbar-width: thin !important;
                scrollbar-color: var(--ytm-sb-thumb) transparent !important;
            }
            ::-webkit-scrollbar {
                width: 14px !important;
                height: 14px !important;
            }
            ::-webkit-scrollbar-track {
                background: transparent !important;
            }
            ::-webkit-scrollbar-thumb {
                background: var(--ytm-sb-thumb) !important;
                border-radius: 100px !important;
                border-right: 3px solid transparent !important;
                background-clip: padding-box !important;
            }
            ::-webkit-scrollbar-thumb:hover {
                background: var(--ytm-sb-thumb-hover) !important;
                border-right: 3px solid transparent !important;
                background-clip: padding-box !important;
            }
            ::-webkit-scrollbar-corner {
                background: transparent !important;
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
                        .forEach(e => v.addEventListener(e, sendTrackInfo));
                }

                // Poll as a safety net: catches metadata that lands after the video
                // events (e.g. artist filled in late) and re-hooks if YT swaps the
                // <video> element. sendTrackInfo dedupes, so the extra calls are cheap.
                setInterval(function() { hookVideo(); sendTrackInfo(); }, 500);
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
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.setValue(false, forKey: "drawsBackground")

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

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var viewModel: YouTubeMusicViewModel
        weak var webView: WKWebView?

        // Visualizer feed state. Both owned on the MainActor; the feed timer fires
        // on the main queue and bridges to them via MainActor.assumeIsolated.
        private var audioTap: AudioTap?
        private var feedTimer: DispatchSourceTimer?

        // Lifecycle gates for the 60 Hz feed. The TAP stays alive while mode is on;
        // only the timer is started/stopped as these flip, so a backgrounded or
        // paused visualizer does no per-frame work. updateFeedTimer() recomputes
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
        /// marks mode active, and lets updateFeedTimer() decide whether the 60 Hz timer
        /// should actually run. Idempotent: a second modeOn while running returns early
        /// so we never stack a second tap.
        @MainActor func startVisualizerFeed(_ webView: WKWebView) {
            if audioTap != nil { return }                 // idempotent: already running
            let tap = AudioTap()
            do {
                try tap.start()
            } catch {
                webView.evaluateJavaScript("window.MilkViz && window.MilkViz.nativeStatus({state:'error',code:'audioCaptureDenied'})")
                return
            }
            audioTap = tap
            modeActive = true
            webView.evaluateJavaScript("window.MilkViz && window.MilkViz.nativeStatus({state:'ok'})")
            updateFeedTimer()
        }

        /// Build (but do not resume) the ~60 Hz timer that pushes base64 stereo Float32
        /// PCM into the page via window.__milkFeed. Factored out so updateFeedTimer can
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
                    let pcm = tap.latestWindow(frames: 2048)              // interleaved stereo
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

        /// Single source of truth for whether the feed timer runs. The feed should run
        /// iff mode is on, the app is active, the window isn't miniaturized, the track is
        /// playing, and a tap exists. Creates+resumes the timer when it should run and is
        /// absent; cancels+nils it when it shouldn't and is present. Never touches the tap.
        @MainActor private func updateFeedTimer() {
            let shouldRun = modeActive && appActive && !windowMiniaturized && trackPlaying && audioTap != nil
            if shouldRun {
                guard feedTimer == nil, let webView else { return }
                let t = makeFeedTimer(webView)
                feedTimer = t
                t.resume()
            } else if feedTimer != nil {
                feedTimer?.cancel(); feedTimer = nil
            }
        }

        @MainActor func stopVisualizerFeed() {
            modeActive = false
            feedTimer?.cancel(); feedTimer = nil
            audioTap?.stop(); audioTap = nil
        }

        /// Register the 4 AppKit lifecycle observers + the track play/pause observer.
        /// Each flips a gate and recomputes the feed timer. Called from makeNSView
        /// (MainActor). Notifications deliver on .main, so assumeIsolated is sound.
        @MainActor func installLifecycleObservers() {
            let nc = NotificationCenter.default
            func observe(_ name: Notification.Name, _ apply: @escaping @MainActor (Coordinator) -> Void) -> NSObjectProtocol {
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { guard let self else { return }; apply(self); self.updateFeedTimer() }
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
                MainActor.assumeIsolated { guard let self else { return }; self.trackPlaying = isPlaying; self.updateFeedTimer() }
            }
        }

        @MainActor func removeLifecycleObservers() {
            for token in lifecycleObservers { NotificationCenter.default.removeObserver(token) }
            lifecycleObservers = []
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
            } else if message.name == "visualizer",
                      let body = message.body as? [String: Any],
                      let action = body["action"] as? String {
                // Hop to the MainActor (this handler is nonisolated) before touching
                // the MainActor-isolated feed lifecycle.
                Task { @MainActor in
                    switch action {
                    case "modeOn":  if let wv = self.webView { self.startVisualizerFeed(wv) }
                    case "modeOff": self.stopVisualizerFeed()
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

