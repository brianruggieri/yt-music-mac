import Foundation

// ponytail: implicitly @MainActor via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor build setting.
final class SpotifyClient {
	private let auth: SpotifyAuth
	private let session: URLSession = .shared

	init(auth: SpotifyAuth) {
		self.auth = auth
	}

	// MARK: - Public API

	func playlists() async throws -> [SpotifyPlaylist] {
		// Show playlists the user can actually import: ones they OWN, plus
		// COLLABORATIVE playlists they contribute to (readable via the
		// playlist-read-collaborative scope). Editorial/algorithmic (owner
		// "spotify") and other users' followed playlists 403 on item read and are
		// excluded; any collaborative one that still 403s is handled by the
		// per-playlist graceful skip in startMatching().
		let myID = try await currentUserID()
		var url: URL? = URL(string: "\(SpotifyConfig.apiBase)/me/playlists?limit=50")
		var results: [SpotifyPlaylist] = []
		while let current = url {
			let page: PlaylistPage = try await get(url: current)
			results += page.items.compactMap(\.value)
				.filter { $0.ownerID == myID || $0.collaborative }
				.map { SpotifyPlaylist(id: $0.id, name: $0.name, trackCount: $0.trackCount) }
			url = page.next.flatMap(URL.init)
		}
		return results
	}

	/// The current user's Spotify ID (cached) — used to keep only own playlists.
	private var cachedUserID: String?
	private func currentUserID() async throws -> String {
		if let id = cachedUserID { return id }
		struct Me: Decodable { let id: String }
		let me: Me = try await get(url: URL(string: "\(SpotifyConfig.apiBase)/me")!)
		cachedUserID = me.id
		return me.id
	}

	func tracks(playlistID: String) async throws -> [SpotifyTrack] {
		// Use /items (Spotify's current Get-Playlist-Items endpoint, per the
		// `items.href` in the playlist object). The legacy /tracks path now
		// returns 403 for newly-created apps.
		var url: URL? = URL(string: "\(SpotifyConfig.apiBase)/playlists/\(playlistID)/items?limit=50")
		var results: [SpotifyTrack] = []
		while let current = url {
			let page: TrackPage = try await get(url: current)
			results += page.items.compactMap(mapTrackItem)
			url = page.next.flatMap(URL.init)
		}
		return results
	}

	func likedSongs() async throws -> [SpotifyTrack] {
		var url: URL? = URL(string: "\(SpotifyConfig.apiBase)/me/tracks?limit=50")
		var results: [SpotifyTrack] = []
		while let current = url {
			let page: TrackPage = try await get(url: current)
			results += page.items.compactMap(mapTrackItem)
			url = page.next.flatMap(URL.init)
		}
		return results
	}

	// MARK: - Mapping

	private func mapTrackItem(_ item: TrackItem) -> SpotifyTrack? {
		// Skip removed/local tracks: track is null, or id is null/empty.
		guard let t = item.track, let id = t.id, !id.isEmpty else { return nil }
		return SpotifyTrack(
			id: id,
			title: t.name,
			artists: t.artists.map(\.name),
			album: t.album?.name,
			durationMs: t.duration_ms,
			isrc: t.external_ids?.isrc
		)
	}

	// MARK: - HTTP

	/// GET with automatic token injection and basic 429 retry (up to 3 attempts).
	private func get<T: Decodable>(url: URL, attempt: Int = 0) async throws -> T {
		let token = try await auth.validAccessToken()
		var req = URLRequest(url: url)
		req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		let (data, response) = try await session.data(for: req)
		guard let http = response as? HTTPURLResponse else {
			throw SpotifyClientError.unexpectedResponse
		}
		if http.statusCode == 429, attempt < 3 {
			// ponytail: bounded 429 retry; Task 9 owns full rate-limit strategy.
			let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
			let delay = max(1, min(retryAfter, 30))
			try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			return try await get(url: url, attempt: attempt + 1)
		}
		guard (200..<300).contains(http.statusCode) else {
			let body = String(data: data, encoding: .utf8) ?? ""
			throw SpotifyClientError.httpError(http.statusCode, body)
		}
		do {
			return try JSONDecoder().decode(T.self, from: data)
		} catch {
			// Surface WHICH type failed and the decoder's coding-path detail
			// instead of the useless generic "data couldn't be read" message.
			throw SpotifyClientError.decodingFailed(String(describing: T.self), String(describing: error))
		}
	}
}

/// Decodes `T`, but yields `nil` instead of throwing on a malformed/null array
/// element — lets one bad item be skipped without aborting the whole page.
private struct FailableDecodable<T: Decodable>: Decodable {
	let value: T?
	init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Codable response types

private struct PlaylistPage: Decodable {
	// Spotify can return null/partial playlist entries (e.g. a playlist owned by
	// a deleted account). Decode leniently so one bad entry doesn't fail the page.
	let items: [FailableDecodable<PlaylistItem>]
	let next: String?
}

private struct PlaylistItem: Decodable {
	let id: String
	let name: String
	let trackCount: Int
	let ownerID: String?
	let collaborative: Bool

	private enum CodingKeys: String, CodingKey { case id, name, tracks, items, owner, collaborative }
	private struct CountObj: Decodable { let total: Int }
	private struct Owner: Decodable { let id: String? }

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id)
		name = try c.decode(String.self, forKey: .name)
		// Spotify now returns the playlist's track-count summary under "items"
		// (dedicated endpoint /playlists/{id}/items); older shape used "tracks".
		// Accept either; default 0 if absent. Count is display-only.
		let count = (try? c.decode(CountObj.self, forKey: .items))
			?? (try? c.decode(CountObj.self, forKey: .tracks))
		trackCount = count?.total ?? 0
		ownerID = (try? c.decode(Owner.self, forKey: .owner))?.id
		collaborative = (try? c.decode(Bool.self, forKey: .collaborative)) ?? false
	}
}

private struct TrackPage: Decodable {
	let items: [TrackItem]
	let next: String?
}

private struct TrackItem: Decodable {
	let track: TrackObject?

	// Custom init: podcast episodes have a different JSON shape (no `artists`),
	// which causes TrackObject to throw. Decode track faillably so a single
	// episode doesn't abort the whole page; mapTrackItem already skips nil tracks.
	// ponytail: if Spotify adds new non-track item types, this handles them too
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		// The /items endpoint nests the track/episode under "item"; the legacy
		// /tracks endpoint and /me/tracks use "track". Try both. TrackObject
		// decode fails for episodes (no artists) → nil → skipped by mapTrackItem.
		track = (try? c.decode(TrackObject.self, forKey: .item))
			?? (try? c.decode(TrackObject.self, forKey: .track))
	}

	private enum CodingKeys: String, CodingKey { case item, track }
}

private struct TrackObject: Decodable {
	let id: String?       // null for local/removed tracks
	let name: String
	let artists: [ArtistObject]
	let album: AlbumObject?
	let duration_ms: Int
	let external_ids: ExternalIds?
}

private struct ArtistObject: Decodable {
	let name: String
}

private struct AlbumObject: Decodable {
	let name: String
}

private struct ExternalIds: Decodable {
	let isrc: String?
}

// MARK: - Errors

enum SpotifyClientError: LocalizedError {
	case unexpectedResponse
	case httpError(Int, String)
	case decodingFailed(String, String)

	var errorDescription: String? {
		switch self {
		case .unexpectedResponse:
			return "Spotify returned an unexpected response."
		case .httpError(let code, let body):
			return "Spotify request failed (HTTP \(code)). \(body.prefix(300))"
		case .decodingFailed(let type, let detail):
			return "Couldn't parse Spotify \(type): \(detail.prefix(400))"
		}
	}
}
