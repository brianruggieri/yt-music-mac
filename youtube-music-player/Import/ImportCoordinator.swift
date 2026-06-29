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
    /// Track IDs the user has resolved (accepted/skipped) in review — hidden from the list.
    @Published var resolvedReviewIDs: Set<String> = []
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
    // ponytail: generation counter — bumped on new run or reset; stale in-flight tasks bail on mismatch
    private var runGeneration = 0
    /// Cached YTM client — warm after startMatching(); reused by search() and confirmAndImport().
    private var cachedYTClient: YTMusicClient?

    // MARK: - Public Methods

    /// Resets to a clean starting state each time the import sheet is (re-)presented.
    /// Optimistically sets isYTMusicSignedIn=true; startMatching() re-gates if the session is missing.
    func resetForPresentation() {
        runGeneration += 1          // Bump first — any in-flight task sees a stale gen and bails
        cancelled = false
        isYTMusicSignedIn = true
        needsReview = []
        resolvedReviewIDs = []
        report = ImportReport()
        errorMessage = nil
        progress = 0
        autoAcceptedCount = 0
        selectedPlaylistIDs = []
        includeLiked = false
        allMatches = [:]
        importSources = []
        cachedYTClient = nil
        if spotifyAuth.isConnected {
            phase = .pickSources
            Task { await loadSources() }  // reload playlists; sets phase = .pickSources on success
        } else {
            phase = .connect
        }
    }

    /// Return to source selection from the matching/review/done screens so the user
    /// can pick a different playlist. Selections are preserved; a re-run resets results.
    func backToSources() {
        runGeneration += 1   // supersede any in-flight matching/import task
        cancelled = true
        phase = .pickSources
    }

    /// Mark a review row resolved (accepted or skipped) so it's hidden from the list.
    /// The chosen value stays on the MatchResult in `needsReview` for import accounting.
    func markReviewed(_ trackID: String) {
        resolvedReviewIDs.insert(trackID)
    }

    /// Token identifying the current run; capture before an async review search and
    /// pass it back to `setReviewCandidates` so a stale search can't mutate a later run.
    var currentRunToken: Int { runGeneration }

    /// Replace a review row's candidates by track id (used by manual YTM search).
    /// Looks the row up by id rather than writing through a possibly-stale array
    /// binding, and fences on the run token so a search from a superseded run (the
    /// user went back / reopened / re-matched, even if the same track reappears)
    /// can't overwrite the new run's candidates. No-op if the row is gone.
    func setReviewCandidates(trackID: String, candidates: [YTMCandidate], runToken: Int) {
        guard runToken == runGeneration,
              let idx = needsReview.firstIndex(where: { $0.track.id == trackID }) else { return }
        needsReview[idx].candidates = candidates
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
        let gen = runGeneration   // ponytail: guard against reset/new-run superseding this fetch
        errorMessage = nil
        do {
            let fetched = try await spotifyClient.playlists()
            guard gen == runGeneration else { return }
            playlists = fetched
            phase = .pickSources
        } catch {
            guard gen == runGeneration else { return }
            errorMessage = error.localizedDescription
            // Stored token is stale/revoked (or load failed) — fall back to Connect so
            // the "Connect Spotify" button is reachable instead of stranding the user on
            // an empty, disabled playlist screen. Connect re-runs OAuth → fresh tokens.
            phase = .connect
        }
    }

    /// Fetches tracks for selected sources, searches YTM, and runs Matcher.
    /// On completion: `phase` = .review, `needsReview` populated.
    func startMatching() async {
        guard !selectedPlaylistIDs.isEmpty || includeLiked else {
            errorMessage = "Select at least one source."
            return
        }

        runGeneration += 1
        let gen = runGeneration
        cancelled = false
        phase = .matching
        progress = 0
        needsReview = []
        resolvedReviewIDs = []
        autoAcceptedCount = 0
        allMatches = [:]
        importSources = []
        errorMessage = nil
        cachedYTClient = nil

        // Acquire YTM session — fail fast if not signed in
        let ytClient: YTMusicClient
        do {
            let session = try await ytMusicAuth.snapshot()
            guard gen == runGeneration else { return }
            ytClient = YTMusicClient(session: session)
            cachedYTClient = ytClient
            isYTMusicSignedIn = true
        } catch YTMusicAuthError.notSignedIn {
            guard gen == runGeneration else { return }
            isYTMusicSignedIn = false
            errorMessage = "Sign in to YouTube Music first."
            phase = .connect
            return
        } catch {
            guard gen == runGeneration else { return }
            errorMessage = error.localizedDescription
            phase = .connect
            return
        }

        // Fetch tracks per source sequentially (Spotify rate-limit friendly).
        // Per-playlist failures are logged but non-fatal.
        var sources: [(label: String, tracks: [SpotifyTrack])] = []
        let selectedPlaylists = playlists.filter { selectedPlaylistIDs.contains($0.id) }
        for playlist in selectedPlaylists {
            guard !cancelled, gen == runGeneration else { break }
            do {
                let tracks = try await spotifyClient.tracks(playlistID: playlist.id)
                if gen == runGeneration {
                    sources.append((playlist.name, tracks))
                }
            } catch {
                if gen == runGeneration {
                    // Spotify forbids Dev-Mode apps from reading items of editorial /
                    // Spotify-owned / some followed playlists (403) — skip with a clear
                    // message rather than a raw HTTP error; other playlists continue.
                    if case SpotifyClientError.httpError(403, _) = error {
                        errorMessage = "Skipped \"\(playlist.name)\" — Spotify doesn't allow importing this playlist (it's editorial or owned by Spotify)."
                    } else {
                        errorMessage = "Couldn't load \"\(playlist.name)\": \(error.localizedDescription)"
                    }
                }
            }
        }
        if includeLiked, !cancelled, gen == runGeneration {
            do {
                let liked = try await spotifyClient.likedSongs()
                if gen == runGeneration {
                    sources.append(("Spotify Liked Songs", liked))
                }
            } catch {
                if gen == runGeneration {
                    errorMessage = "Couldn't load liked songs: \(error.localizedDescription)"
                }
            }
        }

        guard gen == runGeneration else { return }
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
                guard !cancelled, gen == runGeneration, let track = iter.next() else { break }
                group.addTask { await searchAndMatch(track: track, client: ytClient) }
            }

            for await result in group {
                guard gen == runGeneration else { return }
                completed += 1
                progress = Double(completed) / Double(total)
                allMatches[result.track.id] = result

                switch result.confidence {
                case .high:
                    autoAcceptedCount += 1
                case .low, .none:
                    needsReview.append(result)
                }

                // Add next task only if not cancelled and not superseded
                if !cancelled, gen == runGeneration, let next = iter.next() {
                    group.addTask { await searchAndMatch(track: next, client: ytClient) }
                }
            }
        }

        // Always transition to .review — partial needsReview is preserved and the
        // user can proceed or re-run. Leaving phase == .matching on cancel would
        // strand the UI on the progress screen with no exit.
        guard gen == runGeneration else { return }
        phase = .review
    }

    /// Call after the user has resolved `needsReview` items.
    /// Creates one YTM playlist per source, adds matched tracks.
    func confirmAndImport() async {
        runGeneration += 1
        let gen = runGeneration
        cancelled = false
        phase = .importing
        report = ImportReport()
        errorMessage = nil

        // Merge review rows back into allMatches. A row the user explicitly resolved
        // (accepted/skipped) is used as-is. A row left UNREVIEWED is NOT imported —
        // we force its chosen to nil so an unvetted low-confidence guess never lands
        // in the playlist (the review step is opt-in to include, not opt-out).
        for r in needsReview {
            if resolvedReviewIDs.contains(r.track.id) {
                allMatches[r.track.id] = r
            } else {
                var unreviewed = r
                unreviewed.chosen = nil
                allMatches[r.track.id] = unreviewed
            }
        }

        let ytClient: YTMusicClient
        do {
            let session = try await ytMusicAuth.snapshot()
            guard gen == runGeneration else { return }
            ytClient = YTMusicClient(session: session)
            cachedYTClient = ytClient
            isYTMusicSignedIn = true
        } catch YTMusicAuthError.notSignedIn {
            guard gen == runGeneration else { return }
            isYTMusicSignedIn = false
            errorMessage = "Sign in to YouTube Music to continue."
            phase = .review
            return
        } catch {
            guard gen == runGeneration else { return }
            errorMessage = error.localizedDescription
            phase = .review
            return
        }

        for source in importSources {
            guard !cancelled, gen == runGeneration else { break }

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

            // Create the playlist WITH its tracks in one atomic call. Adding to a
            // freshly-created empty playlist via a separate browse/edit_playlist
            // returns 409 ABORTED, so the matched videos go in at creation time.
            // ponytail: very large playlists may exceed the create call's videoIds
            // limit; chunked create + edit can be added later if it becomes a problem.
            do {
                _ = try await withRetry {
                    try await ytClient.createPlaylist(title: source.label, privacy: "PRIVATE", videoIDs: videoIDs)
                }
                guard gen == runGeneration else { break }
                report.imported += videoIDs.count
            } catch {
                guard gen == runGeneration else { break }
                report.failed.append(ImportFailure(
                    track: nil,
                    reason: "Create \"\(source.label)\": \(error.localizedDescription)"))
                continue
            }
        }

        // Always transition to .done — partial report is preserved and displayed.
        // Leaving phase == .importing on cancel would strand the UI on the progress screen.
        guard gen == runGeneration else { return }
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
    func search(_ q: String) async -> [YTMCandidate] {
        (try? await withRetry(maxAttempts: 3) { try await client.search(q) }) ?? []
    }
    // ISRC-first: YouTube indexes ISRCs for official "Art Tracks", so searching the
    // raw ISRC returns the exact recording. The Matcher's title+artist gate confirms
    // it (guards against an un-indexed ISRC returning unrelated results). A confirmed
    // hit is authoritative, so accept it without a second (text) search.
    if let isrc = track.isrc, !isrc.isEmpty {
        let isrcMatch = Matcher.match(track, candidates: await search(isrc), isrcConfirmed: true)
        if isrcMatch.confidence == .high { return isrcMatch }
    }
    // Fall back to a text search (artist + title).
    let query = (track.artists + [track.title]).joined(separator: " ")
    return Matcher.match(track, candidates: await search(query))
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
