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
		var url: URL? = URL(string: "\(SpotifyConfig.apiBase)/me/playlists?limit=50")
		var results: [SpotifyPlaylist] = []
		while let current = url {
			let page: PlaylistPage = try await get(url: current)
			results += page.items.map {
				SpotifyPlaylist(id: $0.id, name: $0.name, trackCount: $0.tracks.total)
			}
			url = page.next.flatMap(URL.init)
		}
		return results
	}

	func tracks(playlistID: String) async throws -> [SpotifyTrack] {
		var url: URL? = URL(string: "\(SpotifyConfig.apiBase)/playlists/\(playlistID)/tracks?limit=100")
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
			throw SpotifyClientError.httpError(http.statusCode)
		}
		return try JSONDecoder().decode(T.self, from: data)
	}
}

// MARK: - Codable response types

private struct PlaylistPage: Decodable {
	let items: [PlaylistItem]
	let next: String?
}

private struct PlaylistItem: Decodable {
	let id: String
	let name: String
	let tracks: TrackCount
}

private struct TrackCount: Decodable {
	let total: Int
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
		track = try? c.decode(TrackObject.self, forKey: .track)
	}

	private enum CodingKeys: String, CodingKey { case track }
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

enum SpotifyClientError: Error {
	case unexpectedResponse
	case httpError(Int)
}
