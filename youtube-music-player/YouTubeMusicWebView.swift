import SwiftUI
import WebKit

@Observable
@MainActor
class YouTubeMusicViewModel {
    weak var webView: WKWebView?
    var onTrackChange: ((String?, String?, URL?, Bool) -> Void)?

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

                // Poll for track changes. The 500ms interval already catches
                // title/artist/play-state changes. A document.body MutationObserver
                // (subtree: true) previously fired sendTrackInfo on nearly every
                // frame because the player bar animates constantly — pinning idle
                // CPU for no coverage the poller doesn't already provide.
                setInterval(sendTrackInfo, 500);
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
                    self.viewModel.onTrackChange?(title, artist, artworkUrl, isPlaying)
                }
            }
        }
    }
}
