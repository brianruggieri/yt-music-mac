import Foundation

enum YTMusicClientError: Error, LocalizedError {
	case invalidURL
	case httpError(Int)
	case invalidResponse
	case missingField(String)

	var errorDescription: String? {
		switch self {
		case .invalidURL: return "Invalid InnerTube URL"
		case .httpError(let code): return "HTTP \(code)"
		case .invalidResponse: return "Non-JSON response"
		case .missingField(let f): return "Missing field: \(f)"
		}
	}
}

final class YTMusicClient {
	private let session: YTMusicSession
	private let urlSession: URLSession
	private let base = "https://music.youtube.com/youtubei/v1"

	init(session: YTMusicSession) {
		self.session = session
		self.urlSession = URLSession.shared
	}

	// MARK: - Public API

	func search(_ query: String) async throws -> [YTMCandidate] {
		let resp = try await post(endpoint: "search", body: ["query": query])
		return parseSearch(resp)
	}

	func createPlaylist(title: String, privacy: String, videoIDs: [String] = []) async throws -> String {
		var body: [String: Any] = [
			"title": title,
			"description": "",
			"privacyStatus": privacy
		]
		// Add the initial tracks atomically at creation (matches ytmusicapi's
		// create_playlist(video_ids:)). A separate edit_playlist on a fresh empty
		// playlist returns 409 ABORTED.
		if !videoIDs.isEmpty { body["videoIds"] = videoIDs }
		let resp = try await post(endpoint: "playlist/create", body: body)
		guard let id = resp["playlistId"] as? String, !id.isEmpty else {
			throw YTMusicClientError.missingField("playlistId")
		}
		return id
	}

	func addItems(playlistID: String, videoIDs: [String]) async throws -> (added: [String], failed: [String]) {
		guard !videoIDs.isEmpty else { return ([], []) }
		let actions: [[String: Any]] = videoIDs.map {
			["action": "ACTION_ADD_VIDEO", "addedVideoId": $0, "dedupeOption": "DEDUPE_OPTION_SKIP"]
		}
		let resp = try await post(endpoint: "browse/edit_playlist", body: [
			"playlistId": playlistID,
			"actions": actions
		])
		let status = resp["status"] as? String ?? ""
		guard status.contains("SUCCEEDED") else { return ([], videoIDs) }

		let results = resp["playlistEditResults"] as? [[String: Any]] ?? []
		// No per-item results returned → treat all as added
		if results.isEmpty { return (videoIDs, []) }

		var added: [String] = []
		for (idx, entry) in results.enumerated() {
			let vid: String?
			if let data = entry["playlistEditVideoAddedResultData"] as? [String: Any] {
				vid = data["videoId"] as? String ?? (idx < videoIDs.count ? videoIDs[idx] : nil)
			} else {
				vid = idx < videoIDs.count ? videoIDs[idx] : nil
			}
			if let vid { added.append(vid) }
		}
		let addedSet = Set(added)
		return (added, videoIDs.filter { !addedSet.contains($0) })
	}

	func deletePlaylist(_ id: String) async throws {
		_ = try await post(endpoint: "playlist/delete", body: ["playlistId": id])
	}

	// MARK: - HTTP

	private func post(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
		guard let url = URL(string: "\(base)/\(endpoint)?key=\(session.apiKey)") else {
			throw YTMusicClientError.invalidURL
		}
		var req = URLRequest(url: url)
		req.httpMethod = "POST"
		req.setValue("application/json", forHTTPHeaderField: "Content-Type")
		req.setValue("*/*", forHTTPHeaderField: "Accept")
		// ponytail: recompute per-request — SAPISIDHASH embeds a timestamp, stale values 401 on long runs
		let ts = Int(Date().timeIntervalSince1970)
		req.setValue(SAPISIDHash.authorization(sapisid: session.sapisid, origin: "https://music.youtube.com", timestamp: ts), forHTTPHeaderField: "Authorization")
		req.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
		req.setValue(session.authUser, forHTTPHeaderField: "X-Goog-AuthUser")
		req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
		req.setValue("https://music.youtube.com", forHTTPHeaderField: "x-origin")
		req.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
		if let vid = session.visitorId { req.setValue(vid, forHTTPHeaderField: "X-Goog-Visitor-Id") }

		var fullBody = body
		fullBody["context"] = session.context
		req.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

		let (data, response) = try await urlSession.data(for: req)
		let code = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard code == 200 else { throw YTMusicClientError.httpError(code) }
		guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw YTMusicClientError.invalidResponse
		}
		return json
	}

	// MARK: - Search parsing

	// ponytail: conservative parse — songs/videos only; albums/artists/playlists skipped (no videoId)
	private func parseSearch(_ resp: [String: Any]) -> [YTMCandidate] {
		let sections = sectionList(from: resp)
		var out: [YTMCandidate] = []
		for section in sections {
			// Top-result card (newer search format puts the best hit here).
			if let card = section["musicCardShelfRenderer"] as? [String: Any],
			   let candidate = parseCard(card) {
				out.append(candidate)
			}
			// Items live under musicShelfRenderer (classic) OR itemSectionRenderer
			// (current format) — both wrap musicResponsiveListItemRenderer in "contents".
			let container = (section["musicShelfRenderer"] as? [String: Any])
				?? (section["itemSectionRenderer"] as? [String: Any])
			guard let items = container?["contents"] as? [[String: Any]] else { continue }
			for item in items {
				guard let mrlir = item["musicResponsiveListItemRenderer"] as? [String: Any],
					  let candidate = parseItem(mrlir) else { continue }
				out.append(candidate)
			}
		}
		return out
	}

	/// Parse the "top result" card (musicCardShelfRenderer) — distinct shape from MRLIR.
	private func parseCard(_ card: [String: Any]) -> YTMCandidate? {
		let watchEp = (card["onTap"] as? [String: Any])?.typed("watchEndpoint")
		guard let videoId = watchEp?["videoId"] as? String else { return nil }
		let videoType = watchEp?
			.typed("watchEndpointMusicSupportedConfigs")?
			.typed("watchEndpointMusicConfig")
			.flatMap { $0["musicVideoType"] as? String }
		let title = ((card["title"] as? [String: Any])?["runs"] as? [[String: Any]])?
			.first?["text"] as? String ?? ""
		guard !title.isEmpty else { return nil }
		var artists: [String] = []
		let subRuns = (card["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
		for r in subRuns {
			let bid = (r["navigationEndpoint"] as? [String: Any])?
				.typed("browseEndpoint")?["browseId"] as? String
			if let bid, bid.hasPrefix("UC"), let t = r["text"] as? String { artists.append(t) }
		}
		return YTMCandidate(videoId: videoId, title: title, artists: artists, album: nil,
							durationMs: nil, resultType: classifyResult(itemBrowseId: nil, videoType: videoType),
							videoType: videoType)
	}

	private func sectionList(from resp: [String: Any]) -> [[String: Any]] {
		// tabbedSearchResultsRenderer path (unfiltered search)
		if let tabbed = (resp["contents"] as? [String: Any])?["tabbedSearchResultsRenderer"] as? [String: Any],
		   let tabs = tabbed["tabs"] as? [[String: Any]],
		   let tab = tabs.first,
		   let content = (tab["tabRenderer"] as? [String: Any])?["content"] as? [String: Any],
		   let sl = content["sectionListRenderer"] as? [String: Any],
		   let contents = sl["contents"] as? [[String: Any]] {
			return contents
		}
		// Direct sectionListRenderer path (filtered search)
		if let contents = resp["contents"] as? [String: Any],
		   let sl = contents["sectionListRenderer"] as? [String: Any],
		   let items = sl["contents"] as? [[String: Any]] {
			return items
		}
		return []
	}

	private func parseItem(_ item: [String: Any]) -> YTMCandidate? {
		// Play button overlay → videoId + videoType
		let playButton = (item["overlay"] as? [String: Any])?
			.typed("musicItemThumbnailOverlayRenderer")?
			.typed("content")?
			.typed("musicPlayButtonRenderer")
		let watchEp = (playButton?["playNavigationEndpoint"] as? [String: Any])?
			.typed("watchEndpoint")
		let videoId = watchEp?["videoId"] as? String
		let videoType = watchEp?
			.typed("watchEndpointMusicSupportedConfigs")?
			.typed("watchEndpointMusicConfig")
			.flatMap { $0["musicVideoType"] as? String }

		// Item's own browse ID for non-playable types
		let itemBrowseId = (item["navigationEndpoint"] as? [String: Any])?
			.typed("browseEndpoint")?["browseId"] as? String

		let resultType = classifyResult(itemBrowseId: itemBrowseId, videoType: videoType)

		// Skip non-playable results (albums, artists, playlists have no videoId)
		guard let videoId else { return nil }

		let cols = item["flexColumns"] as? [[String: Any]] ?? []
		let title = runs(cols, col: 0).first?.text ?? ""
		guard !title.isEmpty else { return nil }

		var artists: [String] = []
		var album: String?
		var durationMs: Int?
		for run in runs(cols, col: 1) {
			if let bid = run.browseId {
				if bid.hasPrefix("UC") { artists.append(run.text) }
				else if bid.hasPrefix("MPRE"), album == nil { album = run.text }
			} else if durationMs == nil, let ms = parseDuration(run.text) {
				durationMs = ms
			}
		}

		return YTMCandidate(
			videoId: videoId, title: title, artists: artists, album: album,
			durationMs: durationMs, resultType: resultType, videoType: videoType
		)
	}

	private func classifyResult(itemBrowseId: String?, videoType: String?) -> YTMResultType {
		if let bid = itemBrowseId {
			if bid.hasPrefix("MPRE") { return .album }
			if bid.hasPrefix("UC") { return .artist }
			if bid.hasPrefix("VL") || bid.hasPrefix("RDCL") { return .playlist }
		}
		guard let vt = videoType else { return .unknown }
		// MUSIC_VIDEO_TYPE_ATV = official audio/music track; others = user upload / official MV
		return vt == "MUSIC_VIDEO_TYPE_ATV" ? .song : .video
	}

	private struct Run { let text: String; let browseId: String? }

	private func runs(_ cols: [[String: Any]], col: Int) -> [Run] {
		guard col < cols.count,
			  let renderer = cols[col]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
			  let textObj = renderer["text"] as? [String: Any],
			  let rawRuns = textObj["runs"] as? [[String: Any]] else { return [] }
		return rawRuns.compactMap { r -> Run? in
			guard let text = r["text"] as? String,
				  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
			let browseId = (r["navigationEndpoint"] as? [String: Any])?
				.typed("browseEndpoint")?["browseId"] as? String
			return Run(text: text, browseId: browseId)
		}
	}

	/// Parse "m:ss" or "h:mm:ss" → milliseconds
	private func parseDuration(_ text: String) -> Int? {
		let parts = text.split(separator: ":").compactMap { Int($0) }
		switch parts.count {
		case 2: return (parts[0] * 60 + parts[1]) * 1000
		case 3: return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000
		default: return nil
		}
	}
}

// Typed dictionary access helper to keep nav paths readable
private extension Dictionary where Key == String, Value == Any {
	func typed(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
}
