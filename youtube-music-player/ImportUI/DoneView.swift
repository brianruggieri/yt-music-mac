import SwiftUI

struct DoneView: View {
	@ObservedObject var coordinator: ImportCoordinator
	let onDismiss: () -> Void
	/// Refresh YT Music (reload webview) so the imported playlist shows in its sidebar.
	var onFinishImport: () -> Void = {}

	@State private var isExpanded = false

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				VStack(spacing: 28) {
					Spacer(minLength: 20)

					// Status icon
					Image(systemName: coordinator.report.failed.isEmpty
						? "checkmark.circle.fill"
						: "exclamationmark.circle.fill")
						.font(.system(size: 52, weight: .light))
						.foregroundStyle(coordinator.report.failed.isEmpty ? Color.green : Color.orange)

					// Title
					Text(coordinator.report.failed.isEmpty ? "Import Complete" : "Imported with Issues")
						.font(.title2).bold()

					// Summary counts
					HStack(spacing: 40) {
						summaryItem(
							count: coordinator.report.imported,
							label: "Imported",
							icon: "music.note",
							color: .green
						)
						summaryItem(
							count: coordinator.report.skipped,
							label: "Skipped",
							icon: "minus.circle",
							color: Color(white: 0.55)
						)
						summaryItem(
							count: coordinator.report.failed.count,
							label: "Failed",
							icon: "exclamationmark.triangle",
							color: coordinator.report.failed.isEmpty ? Color(white: 0.55) : .orange
						)
					}
					.padding(.horizontal, 20)

					// Failure disclosure (only shown when there are failures)
					if !coordinator.report.failed.isEmpty {
						DisclosureGroup(isExpanded: $isExpanded) {
							VStack(alignment: .leading, spacing: 0) {
								ForEach(coordinator.report.failed) { failure in
									HStack(alignment: .top, spacing: 8) {
										Image(systemName: "xmark.circle.fill")
											.font(.caption)
											.foregroundStyle(.orange)
											.padding(.top, 2)
										VStack(alignment: .leading, spacing: 2) {
											if let track = failure.track {
												Text(track.title)
													.font(.caption).bold()
												if !track.artists.isEmpty {
													Text(track.artists.joined(separator: ", "))
														.font(.caption2)
														.foregroundStyle(.secondary)
												}
											}
											Text(failure.reason)
												.font(.caption)
												.foregroundStyle(.secondary)
												.fixedSize(horizontal: false, vertical: true)
										}
										Spacer()
									}
									.padding(.vertical, 6)
									if coordinator.report.failed.last?.id != failure.id {
										Divider()
									}
								}
							}
							.padding(.top, 8)
						} label: {
							Label(
								"\(coordinator.report.failed.count) issue\(coordinator.report.failed.count == 1 ? "" : "s")",
								systemImage: "exclamationmark.triangle.fill"
							)
							.foregroundStyle(.orange)
							.font(.subheadline).bold()
						}
						.padding(16)
						.background(Color.orange.opacity(0.08))
						.overlay(
							RoundedRectangle(cornerRadius: 10)
								.strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
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
				Button("Import another") { coordinator.backToSources() }
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
				Spacer()
				ImportCTAButton(title: "Done", systemImage: "checkmark") {
					// Refresh YT Music on Done (not on appear) — the import write needs a
					// moment to propagate to YTM's backend guide before a reload shows it.
					if coordinator.report.imported > 0 { onFinishImport() }
					onDismiss()
				}
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
	}

	private func summaryItem(count: Int, label: String, icon: String, color: Color) -> some View {
		VStack(spacing: 6) {
			Image(systemName: icon)
				.font(.system(size: 22))
				.foregroundStyle(color)
			Text("\(count)")
				.font(.title2).bold()
			Text(label)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
	}
}
