import Foundation

struct SpotifyTrack: Identifiable, Equatable {
	let id: String
	let title: String
	let artists: [String]
	let album: String?
	let durationMs: Int
	let isrc: String?
}

struct SpotifyPlaylist: Identifiable, Equatable {
	let id: String
	let name: String
	let trackCount: Int
}
