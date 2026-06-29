import Foundation

enum Matcher {
	/// - Parameter isrcConfirmed: pass `true` when `candidates` came from an ISRC
	///   search (the candidates are the exact recording). With ISRC confirmation a
	///   title+artist match is high-confidence even for a video result or one with
	///   no duration, since ISRC already identifies the precise track — the
	///   result-type/duration heuristics only matter for text matches.
	static func match(_ track: SpotifyTrack, candidates: [YTMCandidate], isrcConfirmed: Bool = false) -> MatchResult {
		guard !candidates.isEmpty else {
			return MatchResult(track: track, candidates: [], chosen: nil, confidence: .none)
		}

		let normTitle   = TextNormalize.stripSuffixes(track.title)
		let normArtist  = TextNormalize.normalize(track.artists.first ?? "")
		let trackAlbum  = track.album.map { TextNormalize.normalize($0) }

		struct Scored {
			let candidate: YTMCandidate
			let tier: Int        // 0=high, 1=low
			let albumMatch: Bool
			let durationDiff: Int
		}

		func score(_ c: YTMCandidate) -> Scored {
			let cTitle  = TextNormalize.stripSuffixes(c.title)
			let cArtist = TextNormalize.normalize(c.artists.first ?? "")
			let titleOK  = cTitle == normTitle
			let artistOK = cArtist == normArtist
			let durDiff  = c.durationMs.map { abs($0 - track.durationMs) } ?? Int.max
			// Duration confirms when present (YTM search often omits it). Absent
			// duration does NOT block high — title+artist+song still qualifies;
			// a PRESENT duration off by >2s disqualifies (catches wrong versions).
			let durOK    = c.durationMs.map { abs($0 - track.durationMs) <= 2000 } ?? true
			let albumMatch = c.album.map { TextNormalize.normalize($0) } == trackAlbum

			// High requires a strong title+artist match. Without ISRC confirmation it
			// also requires a catalog song with a close (or absent) duration; with
			// ISRC confirmation the recording is already pinned, so those are waived.
			let strongMatch = titleOK && artistOK
			let songQuality = c.resultType == .song && durOK
			let tier = (strongMatch && (isrcConfirmed || songQuality)) ? 0 : 1
			return Scored(candidate: c, tier: tier, albumMatch: albumMatch, durationDiff: durDiff)
		}

		let scored = candidates.map(score)

		// Best = lowest tier, then album match, then duration closeness
		let best = scored.min { a, b in
			if a.tier != b.tier { return a.tier < b.tier }
			if a.albumMatch != b.albumMatch { return a.albumMatch }
			return a.durationDiff < b.durationDiff
		}!

		let confidence: Confidence
		if best.tier == 0 {
			confidence = .high
		} else {
			confidence = .low
		}

		return MatchResult(track: track, candidates: candidates, chosen: best.candidate, confidence: confidence)
	}
}
