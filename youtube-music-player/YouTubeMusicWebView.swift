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
            } else if message.name == "theme",
                      let body = message.body as? [String: Any],
                      let r = body["r"] as? Int, let g = body["g"] as? Int, let b = body["b"] as? Int {
                let color = NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1.0)
                Task { @MainActor in
                    self.viewModel.headerColor = color
                }
            }
        }
    }
}
