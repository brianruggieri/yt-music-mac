import SwiftUI

struct ConnectView: View {
	@ObservedObject var coordinator: ImportCoordinator
	@Environment(\.dismiss) private var dismiss
	@State private var isConnecting = false

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				VStack(spacing: 28) {
					Spacer(minLength: 20)

					Image(systemName: "music.note.list")
						.font(.system(size: 52, weight: .light))
						.foregroundStyle(.secondary)
						.padding(.top, 8)

					VStack(spacing: 10) {
						Text("Import Your Spotify Library")
							.font(.title2).bold()
						Text("Connect your Spotify account to find and import your playlists and liked songs into YouTube Music.")
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
							.padding(.horizontal, 48)
					}

					// YTM sign-in gate — shown instead of the connect button when not signed in
					if !coordinator.isYTMusicSignedIn {
						HStack(spacing: 12) {
							Image(systemName: "exclamationmark.circle.fill")
								.font(.system(size: 22))
								.foregroundStyle(.orange)
							VStack(alignment: .leading, spacing: 3) {
								Text("Sign in to YouTube Music first")
									.font(.subheadline).bold()
								Text("You must be signed in to YouTube Music before importing. Sign in via the main app window, then try again.")
									.font(.caption)
									.foregroundStyle(.secondary)
									.fixedSize(horizontal: false, vertical: true)
							}
						}
						.padding(16)
						.background(Color.orange.opacity(0.1))
						.overlay(
							RoundedRectangle(cornerRadius: 10)
								.strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
						)
						.clipShape(RoundedRectangle(cornerRadius: 10))
						.padding(.horizontal, 40)
					}
				}
				.frame(maxWidth: .infinity)
				.padding(.bottom, 20)
			}

			Divider()

			HStack {
				Button("Cancel") { dismiss() }
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
				Spacer()
				// Gate hides the button entirely — the callout above is the CTA in that state
				if coordinator.isYTMusicSignedIn {
					ImportCTAButton(
						title: "Connect Spotify",
						systemImage: "link",
						isLoading: isConnecting
					) {
						isConnecting = true
						Task {
							await coordinator.connectSpotify()
							isConnecting = false
						}
					}
				}
			}
			.frame(minHeight: 56)
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
	}
}
