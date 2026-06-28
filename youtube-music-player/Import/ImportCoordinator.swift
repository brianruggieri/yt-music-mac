import Combine
import Foundation
import WebKit

// MARK: - ImportCoordinator

/// Orchestrates Spotify → YouTube Music import.
///
/// Phase flow: connect → pickSources → matching → review → importing → done
///
/// **Task 10 review contract:**
/// After `phase` reaches `.review`, display `needsReview` items. For each:
///   - Accept a candidate: set `coordinator.needsReview[i].chosen = someCandidate`
///   - Skip (no import): set `coordinator.needsReview[i].chosen = nil`
/// Then call `confirmAndImport()`. Tracks with `.high` confidence are auto-accepted
/// (see `autoAcceptedCount`) and will be imported without review.
@MainActor
final class ImportCoordinator: ObservableObject {

    enum Phase {
        case connect, pickSources, matching, review, importing, done
    }

    // MARK: - Published State

    @Published var phase: Phase = .connect
    @Published var playlists: [SpotifyPlaylist] = []
    @Published var selectedPlaylistIDs: Set<String> = []
    @Published var includeLiked = false
    @Published var progress: Double = 0
    @Published var needsReview: [MatchResult] = []
    @Published var autoAcceptedCount = 0
    @Published var report = ImportReport()
    @Published var errorMessage: String?
    @Published var isYTMusicSignedIn = true

    // MARK: - Init

    private let spotifyAuth: SpotifyAuth
    private let spotifyClient: SpotifyClient
    private let ytMusicAuth: YTMusicAuth

    init(webView: WKWebView) {
        spotifyAuth = SpotifyAuth.shared
        spotifyClient = SpotifyClient(auth: SpotifyAuth.shared)
        ytMusicAuth = YTMusicAuth(webView: webView)
    }

    // MARK: - Private State

    /// All match results from the matching phase, keyed by SpotifyTrack.id.
    private var allMatches: [String: MatchResult] = [:]
    /// Sources built during startMatching(); used by confirmAndImport().
    private var importSources: [(label: String, tracks: [SpotifyTrack])] = []
    // ponytail: main-actor bool; cancel() sets it, async methods check between I/O units
    private var cancelled = false
    /// Cached YTM client — warm after startMatching(); reused by search() and confirmAndImport().
    private var cachedYTClient: YTMusicClient?

    // MARK: - Public Methods

    /// Resets to a clean starting state each time the import sheet is (re-)presented.
    /// Optimistically sets isYTMusicSignedIn=true; startMatching() re-gates if the session is missing.
    func resetForPresentation() {
        phase = spotifyAuth.isConnected ? .pickSources : .connect
        isYTMusicSignedIn = true
        needsReview = []
        report = ImportReport()
        errorMessage = nil
        progress = 0
        autoAcceptedCount = 0
        selectedPlaylistIDs = []
        allMatches = [:]
        importSources = []
        cancelled = false
        cachedYTClient = nil
    }

    /// Opens Spotify OAuth. Moves to .pickSources on success.
    func connectSpotify() async {
        errorMessage = nil
        do {
            _ = try await spotifyAuth.authorize()
            await loadSources()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches Spotify playlists. Call directly when `spotifyAuth.isConnected`.
    func loadSources() async {
        errorMessage = nil
        do {
            playlists = try await spotifyClient.playlists()
            phase = .pickSources
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches tracks for selected sources, searches YTM, and runs Matcher.
    /// On completion: `phase` = .review, `needsReview` populated.
    func startMatching() async {
        guard !selectedPlaylistIDs.isEmpty || includeLiked else {
            errorMessage = "Select at least one source."
            return
        }

        cancelled = false
        phase = .matching
        progress = 0
        needsReview = []
        autoAcceptedCount = 0
        allMatches = [:]
        importSources = []
        errorMessage = nil
        cachedYTClient = nil

        // Acquire YTM session — fail fast if not signed in
        let ytClient: YTMusicClient
        do {
            let session = try await ytMusicAuth.snapshot()
            ytClient = YTMusicClient(session: session)
            cachedYTClient = ytClient
            isYTMusicSignedIn = true
        } catch YTMusicAuthError.notSignedIn {
            isYTMusicSignedIn = false
            errorMessage = "Sign in to YouTube Music first."
            phase = .connect
            return
        } catch {
            errorMessage = error.localizedDescription
            phase = .connect
            return
        }

        // Fetch tracks per source sequentially (Spotify rate-limit friendly).
        // Per-playlist failures are logged but non-fatal.
        var sources: [(label: String, tracks: [SpotifyTrack])] = []
        let selectedPlaylists = playlists.filter { selectedPlaylistIDs.contains($0.id) }
        for playlist in selectedPlaylists {
            guard !cancelled else { break }
            do {
                let tracks = try await spotifyClient.tracks(playlistID: playlist.id)
                sources.append((playlist.name, tracks))
            } catch {
                errorMessage = "Couldn't load \"\(playlist.name)\": \(error.localizedDescription)"
            }
        }
        if includeLiked, !cancelled {
            do {
                sources.append(("Spotify Liked Songs", try await spotifyClient.likedSongs()))
            } catch {
                errorMessage = "Couldn't load liked songs: \(error.localizedDescription)"
            }
        }

        importSources = sources

        // Deduplicate tracks across sources (same track may appear in multiple playlists)
        var seen = Set<String>()
        var uniqueTracks: [SpotifyTrack] = []
        for source in sources {
            for track in source.tracks where seen.insert(track.id).inserted {
                uniqueTracks.append(track)
            }
        }

        guard !uniqueTracks.isEmpty else {
            // Always exit matching to a recoverable phase — leaving .matching on cancel
            // strands the UI on the progress screen with no way to close or retry.
            phase = .review
            return
        }

        let total = uniqueTracks.count
        var completed = 0

        // Bounded concurrent search: max 4 YTM searches in-flight at once.
        // ponytail: child tasks are @MainActor; real concurrency via URLSession suspension points
        await withTaskGroup(of: MatchResult.self) { group in
            var iter = uniqueTracks.makeIterator()

            // Seed up to 4
            for _ in 0..<4 {
                guard !cancelled, let track = iter.next() else { break }
                group.addTask { await searchAndMatch(track: track, client: ytClient) }
            }

            for await result in group {
                completed += 1
                progress = Double(completed) / Double(total)
                allMatches[result.track.id] = result

                switch result.confidence {
                case .high:
                    autoAcceptedCount += 1
                case .low, .none:
                    needsReview.append(result)
                }

                // Add next task only if not cancelled
                if !cancelled, let next = iter.next() {
                    group.addTask { await searchAndMatch(track: next, client: ytClient) }
                }
            }
        }

        // Always transition to .review — partial needsReview is preserved and the
        // user can proceed or re-run. Leaving phase == .matching on cancel would
        // strand the UI on the progress screen with no exit.
        phase = .review
    }

    /// Call after the user has resolved `needsReview` items.
    /// Creates one YTM playlist per source, adds matched tracks.
    func confirmAndImport() async {
        cancelled = false
        phase = .importing
        report = ImportReport()
        errorMessage = nil

        // Merge user edits from needsReview back into allMatches
        for r in needsReview { allMatches[r.track.id] = r }

        let ytClient: YTMusicClient
        do {
            let session = try await ytMusicAuth.snapshot()
            ytClient = YTMusicClient(session: session)
            cachedYTClient = ytClient
            isYTMusicSignedIn = true
        } catch YTMusicAuthError.notSignedIn {
            isYTMusicSignedIn = false
            errorMessage = "Sign in to YouTube Music to continue."
            phase = .review
            return
        } catch {
            errorMessage = error.localizedDescription
            phase = .review
            return
        }

        for source in importSources {
            guard !cancelled else { break }

            // Collect video IDs first; nil chosen = user skipped.
            // ponytail: Matcher guarantees chosen != nil for .high — assert so a future
            // Matcher change can't silently drop auto-accepted tracks into report.skipped.
            var videoIDs: [String] = []
            for track in source.tracks {
                guard let match = allMatches[track.id] else {
                    report.skipped += 1
                    continue
                }
                assert(match.confidence != .high || match.chosen != nil,
                       "high-confidence match must have chosen set")
                if let chosen = match.chosen {
                    videoIDs.append(chosen.videoId)
                } else {
                    report.skipped += 1
                }
            }

            // Skip creating a playlist when every track was unmatched or skipped —
            // an empty YTM playlist provides no value and pollutes the user's library.
            guard !videoIDs.isEmpty else {
                report.failed.append(ImportFailure(
                    track: nil,
                    reason: "Skipped \"\(source.label)\" — no matched tracks to import"))
                continue
            }

            let playlistID: String
            do {
                playlistID = try await withRetry {
                    try await ytClient.createPlaylist(title: source.label, privacy: "PRIVATE")
                }
            } catch {
                report.failed.append(ImportFailure(
                    track: nil,
                    reason: "Create \"\(source.label)\": \(error.localizedDescription)"))
                continue
            }

            // Add in batches of 25
            // ponytail: 25 is conservative; increase if YTM allows larger undocumented batches
            let batchSize = 25
            var offset = 0
            while offset < videoIDs.count {
                guard !cancelled else { break }
                let batch = Array(videoIDs[offset..<min(offset + batchSize, videoIDs.count)])
                offset += batchSize
                do {
                    let (added, failed) = try await withRetry {
                        try await ytClient.addItems(playlistID: playlistID, videoIDs: batch)
                    }
                    report.imported += added.count
                    for vid in failed {
                        report.failed.append(ImportFailure(
                            track: nil,
                            reason: "\(vid) failed in \"\(source.label)\""))
                    }
                } catch {
                    report.failed.append(ImportFailure(
                        track: nil,
                        reason: "Batch add to \"\(source.label)\": \(error.localizedDescription)"))
                }
            }
        }

        // Always transition to .done — partial report is preserved and displayed.
        // Leaving phase == .importing on cancel would strand the UI on the progress screen.
        phase = .done
    }

    /// Searches YouTube Music for `query`. Never throws — returns [] on failure.
    /// Reuses the cached YTM client from startMatching(); snapshots a fresh session if not available.
    func search(_ query: String) async -> [YTMCandidate] {
        if cachedYTClient == nil {
            guard let session = try? await ytMusicAuth.snapshot() else { return [] }
            cachedYTClient = YTMusicClient(session: session)
        }
        guard let client = cachedYTClient else { return [] }
        return (try? await client.search(query)) ?? []
    }

    /// Stops issuing new work. Preserves partial `needsReview` and `report`.
    func cancel() {
        cancelled = true
    }

    /// Runs the YTM write preflight (create → add → delete) and returns a human-readable result.
    /// Never throws — all errors are surfaced in the returned string.
    func runWriteDiagnostic() async -> String {
        do {
            let session = try await ytMusicAuth.snapshot()
            let client = YTMusicClient(session: session)
            let result = await YTMusicDiagnostic.runWritePreflight(client)
            switch result {
            case .success:
                return "Write preflight PASSED — create / add / delete all succeeded."
            case .failure(let e):
                return "Write preflight FAILED: \(e.localizedDescription)"
            }
        } catch YTMusicAuthError.notSignedIn {
            return "Write preflight SKIPPED — not signed in to YouTube Music."
        } catch {
            return "Write preflight SKIPPED — session error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Free helpers (implicitly @MainActor via SWIFT_DEFAULT_ACTOR_ISOLATION)

/// Searches YTM for `track` and returns a MatchResult.
/// Never throws — search failures produce empty candidates → .none confidence.
private func searchAndMatch(track: SpotifyTrack, client: YTMusicClient) async -> MatchResult {
    let query = (track.artists + [track.title]).joined(separator: " ")
    let candidates: [YTMCandidate]
    do {
        candidates = try await withRetry(maxAttempts: 3) {
            try await client.search(query)
        }
    } catch {
        candidates = []
    }
    return Matcher.match(track, candidates: candidates)
}

/// Retries `work` on 429 / 5xx with exponential backoff (1 s → 2 s → 4 s … capped at 30 s).
/// ponytail: Retry-After header unavailable from YTMusicClientError; exponential fallback only
private func withRetry<T>(
    maxAttempts: Int = 3,
    _ work: () async throws -> T
) async throws -> T {
    var delay: Double = 1.0
    var lastError: Error = YTMusicClientError.invalidResponse
    for attempt in 0..<maxAttempts {
        do {
            return try await work()
        } catch let e as YTMusicClientError where isRetryable(e) {
            lastError = e
            if attempt < maxAttempts - 1 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, 30)
            }
        } catch {
            throw error  // non-retryable — propagate immediately
        }
    }
    throw lastError
}

private func isRetryable(_ e: YTMusicClientError) -> Bool {
    guard case .httpError(let code) = e else { return false }
    return code == 429 || code >= 500
}

// MARK: - Report types

struct ImportReport {
    var imported: Int = 0
    var skipped: Int = 0
    var failed: [ImportFailure] = []
}

struct ImportFailure: Identifiable {
    let id = UUID()
    let track: SpotifyTrack?  // nil for playlist-level failures
    let reason: String
}
