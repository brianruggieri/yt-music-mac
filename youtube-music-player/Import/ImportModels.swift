import Foundation

enum Confidence {
	case high
	case low
	case none
}

struct MatchResult: Identifiable {
	let track: SpotifyTrack
	var candidates: [YTMCandidate]
	var chosen: YTMCandidate?
	var confidence: Confidence
	var id: String { track.id }
}
