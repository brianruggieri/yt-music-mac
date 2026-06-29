import SwiftUI

// MARK: - ReviewView

struct ReviewView: View {
	@ObservedObject var coordinator: ImportCoordinator
	@State private var isConfirming = false

	/// Tracks that will be imported: auto-accepted (high) + review rows the user
	/// explicitly resolved AND accepted. Unreviewed low-confidence rows don't import.
	private var importCount: Int {
		coordinator.autoAcceptedCount + coordinator.needsReview.filter {
			coordinator.resolvedReviewIDs.contains($0.track.id) && $0.chosen != nil
		}.count
	}

	/// Review items the user hasn't accepted/skipped yet.
	private var unresolvedCount: Int {
		coordinator.needsReview.filter { !coordinator.resolvedReviewIDs.contains($0.track.id) }.count
	}

	var body: some View {
		VStack(spacing: 0) {
			// Summary bar
			HStack(spacing: 8) {
				Image(systemName: "checkmark.circle.fill")
					.foregroundStyle(.green)
					.font(.subheadline)
				Text("\(coordinator.autoAcceptedCount) matched automatically")
					.font(.subheadline)
				if unresolvedCount > 0 {
					Text("·")
						.foregroundStyle(.tertiary)
					Text("\(unresolvedCount) to review")
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
				Spacer()
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 10)
			.background(Color.ytSurf.opacity(0.7))

			Divider()

			if unresolvedCount == 0 {
				emptyReviewState
			} else {
				List {
					ForEach($coordinator.needsReview) { $result in
						// Hide rows the user has already accepted/skipped.
						if !coordinator.resolvedReviewIDs.contains(result.track.id) {
							ReviewRow(result: $result, coordinator: coordinator)
								.listRowBackground(Color.ytSurf.opacity(0.5))
								.listRowSeparator(.visible)
						}
					}
				}
				.listStyle(.inset)
				.scrollContentBackground(.hidden)
			}

			Divider()

			HStack {
				Button("Back") { coordinator.backToSources() }
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
				Spacer()
				ImportCTAButton(
					title: "Import \(importCount) \(importCount == 1 ? "song" : "songs")",
					systemImage: "arrow.down.circle",
					isLoading: isConfirming
				) {
					isConfirming = true
					Task {
						await coordinator.confirmAndImport()
						isConfirming = false
					}
				}
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
	}

	private var emptyReviewState: some View {
		VStack(spacing: 12) {
			Spacer()
			Image(systemName: "checkmark.seal.fill")
				.font(.system(size: 40))
				.foregroundStyle(.green)
			Text("All tracks matched automatically")
				.font(.subheadline).bold()
			Text("Nothing to review. Tap Import to add everything to YouTube Music.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 60)
			Spacer()
		}
		.frame(maxHeight: .infinity)
	}
}

// MARK: - ReviewRow

private struct ReviewRow: View {
	@Binding var result: MatchResult
	let coordinator: ImportCoordinator
	@State private var isSearching = false
	@State private var searchText = ""
	@State private var isYTMSearching = false

	/// Client-side filter over candidates; live YTM search replaces candidates on submit.
	private var filteredCandidates: [YTMCandidate] {
		guard !searchText.isEmpty else { return result.candidates }
		let q = searchText.lowercased()
		return result.candidates.filter {
			$0.title.lowercased().contains(q) ||
			$0.artists.joined(separator: " ").lowercased().contains(q)
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(alignment: .top, spacing: 12) {
				// Spotify track info
				VStack(alignment: .leading, spacing: 3) {
					Text(result.track.title)
						.font(.subheadline).bold()
						.lineLimit(2)
						.foregroundStyle(result.chosen == nil ? .tertiary : .primary)
						.help(result.track.title)
					Text(result.track.artists.joined(separator: ", "))
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.help(result.track.artists.joined(separator: ", "))
				}
				.frame(maxWidth: .infinity, alignment: .leading)

				Image(systemName: "arrow.right")
					.font(.caption)
					.foregroundStyle(.tertiary)
					.padding(.top, 4)

				// Chosen YTM candidate (or skipped/not-found state)
				VStack(alignment: .leading, spacing: 3) {
					if let chosen = result.chosen {
						Text(chosen.title)
							.font(.subheadline)
							.lineLimit(2)
							.help(chosen.title)
						if !chosen.artists.isEmpty {
							Text(chosen.artists.joined(separator: ", "))
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
					} else if result.confidence == .none {
						Text("No match found")
							.font(.subheadline)
							.foregroundStyle(.tertiary)
							.italic()
					} else {
						Text("Skipped")
							.font(.subheadline)
							.foregroundStyle(.tertiary)
							.italic()
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)

				// Confidence badge + action menu
				VStack(alignment: .trailing, spacing: 6) {
					ConfidenceBadge(confidence: result.confidence)
					actionsMenu
				}
			}
			.padding(.vertical, 10)

			// Inline candidate filter panel (toggled from menu)
			if isSearching {
				candidateSearchPanel
					.padding(.bottom, 10)
					.transition(.opacity.combined(with: .move(edge: .top)))
			}
		}
	}

	private var actionsMenu: some View {
		Menu {
			if let best = result.candidates.first {
				Button {
					result.chosen = best; coordinator.markReviewed(result.track.id)
					isSearching = false
				} label: {
					Label("Accept \"\(best.title)\"", systemImage: "checkmark")
				}

				if result.candidates.count > 1 {
					Divider()
					// Alternates: show up to 5, skipping the first (already shown as Accept)
					ForEach(Array(result.candidates.dropFirst().prefix(4))) { candidate in
						Button {
							result.chosen = candidate; coordinator.markReviewed(result.track.id)
							isSearching = false
						} label: {
							let artist = candidate.artists.first ?? ""
							Text(candidate.title + (artist.isEmpty ? "" : " · \(artist)"))
						}
					}
				}

				Divider()
			}

			// Toggle inline candidate search/filter panel
			Button {
				withAnimation(.easeInOut(duration: 0.18)) { isSearching.toggle() }
			} label: {
				Label(
					isSearching ? "Hide search" : (result.candidates.isEmpty ? "Search YouTube Music…" : "Filter candidates…"),
					systemImage: "magnifyingglass"
				)
			}

			Divider()

			// Skip — set chosen to nil
			Button(role: .destructive) {
				result.chosen = nil; coordinator.markReviewed(result.track.id)
				isSearching = false
			} label: {
				Label("Skip this track", systemImage: "xmark.circle")
			}
		} label: {
			Image(systemName: "ellipsis.circle")
				.font(.system(size: 15))
				.foregroundStyle(.secondary)
		}
		.menuIndicator(.hidden)
		.fixedSize()
	}

	private var candidateSearchPanel: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "magnifyingglass")
					.font(.caption)
					.foregroundStyle(.secondary)
				TextField(result.candidates.isEmpty ? "Search YouTube Music…" : "Filter candidates…", text: $searchText)
					.font(.caption)
					.textFieldStyle(.plain)
					.onSubmit {
						guard !searchText.isEmpty else { return }
						let query = searchText
						let trackID = result.track.id  // capture before await — binding may go stale on reset
						let runToken = coordinator.currentRunToken  // fence against a superseded run
						Task {
							isYTMSearching = true
							let hits = await coordinator.search(query)
							// Update by id + run token, not the (possibly stale) $result binding.
							coordinator.setReviewCandidates(trackID: trackID, candidates: hits, runToken: runToken)
							searchText = ""
							isYTMSearching = false
						}
					}
				if isYTMSearching {
					ProgressView()
						.controlSize(.small)
						.scaleEffect(0.8)
				}
			}
			.padding(7)
			.background(Color.ytBg)
			.clipShape(RoundedRectangle(cornerRadius: 7))

			if isYTMSearching {
				// progress shown inline above
			} else if result.candidates.isEmpty {
				Text("Type a query and press Return to search YouTube Music")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.padding(.horizontal, 4)
			} else if filteredCandidates.isEmpty {
				Text("No matches for \"\(searchText)\"")
					.font(.caption)
					.foregroundStyle(.tertiary)
					.padding(.horizontal, 4)
			} else {
				ForEach(Array(filteredCandidates.prefix(4))) { candidate in
					Button {
						result.chosen = candidate; coordinator.markReviewed(result.track.id)
						isSearching = false
						searchText = ""
					} label: {
						HStack {
							VStack(alignment: .leading, spacing: 1) {
								Text(candidate.title)
									.font(.caption).bold()
									.lineLimit(1)
									.foregroundStyle(.primary)
								if !candidate.artists.isEmpty {
									Text(candidate.artists.joined(separator: ", "))
										.font(.caption2)
										.foregroundStyle(.secondary)
										.lineLimit(1)
								}
							}
							Spacer()
							if result.chosen?.id == candidate.id {
								Image(systemName: "checkmark")
									.font(.caption)
									.foregroundStyle(Color.ytRed)
							}
						}
						.padding(.vertical, 5)
						.padding(.horizontal, 8)
						.background(result.chosen?.id == candidate.id ? Color.ytRed.opacity(0.15) : Color.ytSurf)
						.clipShape(RoundedRectangle(cornerRadius: 6))
					}
					.buttonStyle(.plain)
				}
				if filteredCandidates.count > 4 {
					Text("… and \(filteredCandidates.count - 4) more")
						.font(.caption2)
						.foregroundStyle(.tertiary)
						.padding(.horizontal, 4)
				}
			}
		}
	}
}
