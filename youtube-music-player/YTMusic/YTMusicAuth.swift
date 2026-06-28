import Foundation
import WebKit

enum YTMusicAuthError: Error {
	case notSignedIn
	case configUnavailable
}

@MainActor
final class YTMusicAuth {
	private let webView: WKWebView

	init(webView: WKWebView) {
		self.webView = webView
	}

	func snapshot() async throws -> YTMusicSession {
		// 1. Read all cookies from the webview's data store
		let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
		// ponytail: domain suffix match covers both .youtube.com and music.youtube.com
		let ytCookies = cookies.filter { $0.domain.hasSuffix("youtube.com") }

		guard let sapisid = ytCookies.first(where: { $0.name == "__Secure-3PAPISID" })?.value else {
			throw YTMusicAuthError.notSignedIn
		}

		// 2. Build Cookie header — join all youtube.com cookies
		let cookieHeader = ytCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

		// 3. Build signed Authorization header
		let timestamp = Int(Date().timeIntervalSince1970)
		let authorization = SAPISIDHash.authorization(
			sapisid: sapisid,
			origin: "https://music.youtube.com",
			timestamp: timestamp
		)

		// 4. Read ytcfg from the live page — one-shot JS, returns JSON string or null
		let js = """
		(function(){try{return JSON.stringify({
		  apiKey: window.ytcfg && window.ytcfg.get('INNERTUBE_API_KEY'),
		  context: window.ytcfg && window.ytcfg.get('INNERTUBE_CONTEXT'),
		  visitor: window.ytcfg && window.ytcfg.get('VISITOR_DATA'),
		  user: String((window.ytcfg && window.ytcfg.get('SESSION_INDEX')) || '0')
		});}catch(e){return null;}})()
		"""

		guard
			let raw = try await webView.evaluateJavaScript(js) as? String,
			let data = raw.data(using: .utf8),
			let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let apiKey = json["apiKey"] as? String, !apiKey.isEmpty,
			let context = json["context"] as? [String: Any]
		else {
			throw YTMusicAuthError.configUnavailable
		}

		let visitorId = json["visitor"] as? String
		let authUser = json["user"] as? String ?? "0"

		return YTMusicSession(
			cookieHeader: cookieHeader,
			authorization: authorization,
			visitorId: visitorId,
			authUser: authUser,
			apiKey: apiKey,
			context: context
		)
	}
}
