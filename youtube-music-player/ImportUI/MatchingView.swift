import SwiftUI

/// Reused for both .matching (determinate progress) and .importing (indeterminate spinner).
struct MatchingView: View {
	@ObservedObject var coordinator: ImportCoordinator
	let isImporting: Bool

	var body: some View {
		VStack(spacing: 0) {
			Spacer()

			VStack(spacing: 24) {
				Image(systemName: isImporting ? "arrow.down.circle" : "waveform.badge.magnifyingglass")
					.font(.system(size: 48, weight: .light))
					.foregroundStyle(Color.ytRed)

				VStack(spacing: 8) {
					Text(isImporting ? "Importing…" : "Matching Tracks…")
						.font(.title3).bold()
					Text(isImporting
						? "Adding your library to YouTube Music. This may take a few minutes."
						: "Searching YouTube Music for each track. Large libraries may take a while.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.padding(.horizontal, 60)
				}

				if isImporting {
					ProgressView()
						.controlSize(.large)
						.padding(.top, 4)
				} else {
					VStack(spacing: 6) {
						ProgressView(value: coordinator.progress)
							.progressViewStyle(.linear)
							.tint(Color.ytRed)
							.frame(width: 280)
						Text("\(Int(coordinator.progress * 100))%")
							.font(.caption)
							.foregroundStyle(.secondary)
							.monospacedDigit()
					}
					.padding(.top, 4)
				}
			}
			.frame(maxWidth: .infinity)

			Spacer()

			Divider()

			HStack {
				Button("Cancel") {
					coordinator.cancel()
				}
				.buttonStyle(.plain)
				.foregroundStyle(.secondary)
				Spacer()
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
	}
}
