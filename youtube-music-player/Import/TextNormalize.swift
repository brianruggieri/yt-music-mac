import Foundation

enum TextNormalize {
	/// Lowercase, strip diacritics, remove punctuation, collapse whitespace.
	static func normalize(_ s: String) -> String {
		let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
		let noPunct = folded.unicodeScalars.filter { scalar in
			let cat = scalar.properties.generalCategory
			return cat != .otherPunctuation &&
				cat != .openPunctuation &&
				cat != .closePunctuation &&
				cat != .dashPunctuation &&
				cat != .connectorPunctuation &&
				cat != .initialPunctuation &&
				cat != .finalPunctuation
		}
		let joined = String(String.UnicodeScalarView(noPunct))
		return joined.components(separatedBy: .whitespaces)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}

	/// normalize() then strip parenthetical/bracket noise for comparison.
	static func stripSuffixes(_ s: String) -> String {
		// Remove (...) and [...] blocks ONLY when they contain noise keywords.
		// Noise = metadata that doesn't denote a different artistic version.
		// NOT stripped: live, acoustic, demo, remix, radio edit, extended, single version,
		//               instrumental, karaoke, cover, session, version.
		// NOTE: "live" is a VERSION MARKER — both "(Live)" and "- Live" forms are intentionally
		//       preserved so a live recording never wrong-matches a studio version.
		// ponytail: keyword list covers known noise; add here if new noise patterns emerge
		let noiseKw = "remaster(?:ed)?|reissue|anniversary|edition|explicit|clean|mono|stereo|feat|ft|original\\s+mix|bonus\\s+track|deluxe"
		var result = s
		let patterns = [
			"(?i)\\s*\\((?=[^)]*\\b(?:\(noiseKw))\\b)[^)]*\\)",    // (...) containing noise keyword
			"(?i)\\s*\\[(?=[^\\]]*\\b(?:\(noiseKw))\\b)[^\\]]*\\]", // [...] containing noise keyword
			"(?i)\\s*-\\s*remaster\\w*", // "- remaster" / "- remastered"
			"(?i)\\s*feat\\.?\\s+[^,]*", // "feat. ..." at end
		]
		for pattern in patterns {
			if let regex = try? NSRegularExpression(pattern: pattern, options: []) { // (?i) inline; .caseInsensitive redundant
				let range = NSRange(result.startIndex..., in: result)
				result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
			}
		}
		return normalize(result.trimmingCharacters(in: .whitespaces))
	}
}
