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

                function sendTrackInfo() {
                    const titleEl = document.querySelector('.title.ytmusic-player-bar, .title.style-scope.ytmusic-player-bar');
                    const artistEl = document.querySelector('.byline.ytmusic-player-bar a, .subtitle .byline a');
                    const imgEl = document.querySelector('.image.ytmusic-player-bar img, img.image.style-scope.ytmusic-player-bar');
                    const video = document.querySelector('video');

                    const title = titleEl?.textContent?.trim() || '';
                    const artist = artistEl?.textContent?.trim() || '';
                    const isPlaying = video ? !video.paused : false;

                    // Get larger artwork
                    let artwork = imgEl?.src || '';
                    if (artwork) {
                        artwork = artwork.replace(/=w\d+-h\d+-.*$/, '=w500-h500-l90-rj');
                        if (!artwork.includes('=w500')) {
                            artwork = artwork.replace(/=s\d+/, '=s500');
                        }
                    }

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

                // Poll for track changes. The 500ms interval (2x/sec) already catches
                // title/artist/play-state changes. A document.body subtree
                // MutationObserver previously also ran sendTrackInfo on every DOM
                // mutation. Measured on WebKit: ~0/sec while idle or paused, but
                // ~5-8/sec during playback (the progress bar and time readout mutate
                // constantly) — 2-4x the poll, all redundant since the poll already
                // covers the same fields within 500ms.
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
