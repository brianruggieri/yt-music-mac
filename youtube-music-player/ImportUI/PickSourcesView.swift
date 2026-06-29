import SwiftUI

struct PickSourcesView: View {
	@ObservedObject var coordinator: ImportCoordinator
	@Environment(\.dismiss) private var dismiss
	@State private var isStarting = false

	private var canContinue: Bool {
		!coordinator.selectedPlaylistIDs.isEmpty || coordinator.includeLiked
	}

	/// Creates a Bool binding that reads/writes coordinator.selectedPlaylistIDs for a single playlist.
	private func selectionBinding(for playlist: SpotifyPlaylist) -> Binding<Bool> {
		Binding(
			get: { coordinator.selectedPlaylistIDs.contains(playlist.id) },
			set: { selected in
				if selected {
					coordinator.selectedPlaylistIDs.insert(playlist.id)
				} else {
					coordinator.selectedPlaylistIDs.remove(playlist.id)
				}
			}
		)
	}

	var body: some View {
		VStack(spacing: 0) {
			sourceList

			Divider()

			HStack {
				Button("Cancel") { dismiss() }
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
				Spacer()
				ImportCTAButton(
					title: "Continue",
					systemImage: "arrow.right",
					isLoading: isStarting,
					disabled: !canContinue
				) {
					isStarting = true
					Task {
						await coordinator.startMatching()
						isStarting = false
					}
				}
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
	}

	private var sourceList: some View {
		List {
			Section {
				Toggle(isOn: $coordinator.includeLiked) {
					Label {
						VStack(alignment: .leading, spacing: 1) {
							Text("Liked Songs")
								.font(.subheadline)
							Text("Your saved tracks on Spotify")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					} icon: {
						Image(systemName: "heart.fill")
							.foregroundStyle(Color.ytRed)
					}
				}
				.toggleStyle(.checkbox)
				.padding(.vertical, 4)
			}

			Section("Playlists") {
				if coordinator.playlists.isEmpty {
					Text("No playlists found on this account")
						.font(.caption)
						.foregroundStyle(.tertiary)
						.frame(maxWidth: .infinity, alignment: .center)
						.padding(.vertical, 10)
				} else {
					ForEach(coordinator.playlists) { playlist in
						Toggle(isOn: selectionBinding(for: playlist)) {
							VStack(alignment: .leading, spacing: 2) {
								Text(playlist.name)
									.font(.subheadline)
								Text("\(playlist.trackCount) \(playlist.trackCount == 1 ? "track" : "tracks")")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						.toggleStyle(.checkbox)
						.padding(.vertical, 3)
					}
				}
			}
		}
		.listStyle(.inset)
		.scrollContentBackground(.hidden)
	}
}
