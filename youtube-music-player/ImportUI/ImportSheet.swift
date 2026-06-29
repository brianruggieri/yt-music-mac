import SwiftUI

// MARK: - Design tokens (import flow)

extension Color {
	/// YouTube Music dark background #212121
	static let ytBg   = Color(red: 0.129, green: 0.129, blue: 0.129)
	/// Slightly lighter surface for secondary areas
	static let ytSurf = Color(red: 0.173, green: 0.173, blue: 0.173)
	/// YouTube red accent — used sparingly for CTAs only
	static let ytRed  = Color(red: 1.0, green: 0.0, blue: 0.0)
}

extension Confidence {
	var badgeLabel: String {
		switch self {
		case .high: "Match"
		case .low:  "Check"
		case .none: "Not found"
		}
	}
	var badgeColor: Color {
		switch self {
		case .high: .green
		case .low:  .orange
		case .none: Color(red: 1.0, green: 0.35, blue: 0.35)
		}
	}
}

extension ImportCoordinator.Phase {
	var stepSubtitle: String {
		switch self {
		case .connect:     "Connect your Spotify account"
		case .pickSources: "Choose what to import"
		case .matching:    "Matching tracks on YouTube Music…"
		case .review:      "Review low-confidence matches"
		case .importing:   "Adding tracks to YouTube Music…"
		case .done:        "Import complete"
		}
	}
}

// MARK: - ImportSheet

/// Top-level sheet container. Present via `.sheet(isPresented:) { ImportSheet(coordinator:) }`.
/// Task 11 wires this into the app; this file is UI-only.
struct ImportSheet: View {
	@ObservedObject var coordinator: ImportCoordinator
	/// Called when the user taps Done after a successful import (used to refresh YT Music).
	var onFinishImport: () -> Void = {}
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(spacing: 0) {
			ImportSheetHeader(phase: coordinator.phase) { dismiss() }
			Divider()

			if let msg = coordinator.errorMessage {
				ErrorBanner(message: msg) { coordinator.errorMessage = nil }
			}

			switch coordinator.phase {
			case .connect:
				ConnectView(coordinator: coordinator)
			case .pickSources:
				PickSourcesView(coordinator: coordinator)
			case .matching:
				MatchingView(coordinator: coordinator, isImporting: false)
			case .review:
				ReviewView(coordinator: coordinator)
			case .importing:
				MatchingView(coordinator: coordinator, isImporting: true)
			case .done:
				DoneView(coordinator: coordinator, onDismiss: { dismiss() }, onFinishImport: onFinishImport)
			}
		}
		.frame(width: 600, height: 520)
		.background(Color.ytBg)
		.preferredColorScheme(.dark)
		.animation(.easeInOut(duration: 0.22), value: coordinator.phase)
	}
}

// MARK: - Sheet header

private struct ImportSheetHeader: View {
	let phase: ImportCoordinator.Phase
	let onClose: () -> Void

	var body: some View {
		HStack {
			VStack(alignment: .leading, spacing: 3) {
				Text("Import from Spotify")
					.font(.title3).bold()
				Text(phase.stepSubtitle)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Button(action: onClose) {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 18))
					.foregroundStyle(.tertiary)
			}
			.buttonStyle(.plain)
			.help("Close")
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 16)
	}
}

// MARK: - Error banner

private struct ErrorBanner: View {
	let message: String
	let onDismiss: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange)
			Text(message)
				.font(.caption)
				.foregroundStyle(.primary)
				.lineLimit(2)
			Spacer()
			Button(action: onDismiss) {
				Image(systemName: "xmark")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 10)
		.background(Color.orange.opacity(0.12))
	}
}

// MARK: - Shared: primary CTA button

struct ImportCTAButton: View {
	let title: String
	var systemImage: String? = nil
	var isLoading: Bool = false
	var disabled: Bool = false
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if isLoading {
					ProgressView()
						.controlSize(.small)
						.tint(.white)
				} else if let img = systemImage {
					Image(systemName: img)
				}
				Text(title).font(.headline)
			}
			.padding(.vertical, 8)
			.padding(.horizontal, 20)
		}
		.buttonStyle(.borderedProminent)
		.tint(Color.ytRed)
		.disabled(isLoading || disabled)
	}
}

// MARK: - Shared: confidence badge

struct ConfidenceBadge: View {
	let confidence: Confidence

	var body: some View {
		Text(confidence.badgeLabel)
			.font(.caption2).bold()
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(confidence.badgeColor.opacity(0.2))
			.foregroundStyle(confidence.badgeColor)
			.clipShape(Capsule())
	}
}
