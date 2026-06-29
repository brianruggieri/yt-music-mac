import AppKit
import SwiftUI
import WebKit

@Observable
@MainActor
class YouTubeMusicViewModel {
    weak var webView: WKWebView?

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

        // Inject scrollbar CSS at document start
        let css = """
            *, *::before, *::after {
                scrollbar-width: thin !important;
                scrollbar-color: rgba(255,255,255,0.15) transparent !important;
            }
            ::-webkit-scrollbar {
                width: 14px !important;
                height: 14px !important;
            }
            ::-webkit-scrollbar-track {
                background: transparent !important;
            }
            ::-webkit-scrollbar-thumb {
                background: rgba(255, 255, 255, 0.15) !important;
                border-radius: 100px !important;
                border-right: 3px solid transparent !important;
                background-clip: padding-box !important;
            }
            ::-webkit-scrollbar-thumb:hover {
                background: rgba(255, 255, 255, 0.25) !important;
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.setValue(false, forKey: "drawsBackground")

        viewModel.webView = webView

        if let url = URL(string: "https://music.youtube.com") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var viewModel: YouTubeMusicViewModel

        init(viewModel: YouTubeMusicViewModel) {
            self.viewModel = viewModel
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
