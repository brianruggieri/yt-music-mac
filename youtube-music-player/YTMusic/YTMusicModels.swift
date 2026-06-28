import Foundation

enum YTMResultType: String {
	case song
	case video
	case album
	case playlist
	case artist
	case unknown
}

struct YTMCandidate: Identifiable, Equatable {
	let videoId: String
	let title: String
	let artists: [String]
	let album: String?
	let durationMs: Int?
	let resultType: YTMResultType
	let videoType: String?
	var id: String { videoId }
}

struct YTMusicSession {
	let cookieHeader: String
	let sapisid: String
	let visitorId: String?
	let authUser: String
	let apiKey: String
	let context: [String: Any]
}
