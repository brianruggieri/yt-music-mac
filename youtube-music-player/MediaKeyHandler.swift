import Foundation
import MediaPlayer
import AppKit

@Observable
@MainActor
class MediaKeyHandler {
    private var viewModel: YouTubeMusicViewModel?
    private var currentArtwork: NSImage?
    private let artworkCache = NSCache<NSURL, NSImage>()
    private var lastArtworkUrl: URL?

    init() {
        setupRemoteCommandCenter()
        becomeNowPlaying()
    }

    func setViewModel(_ viewModel: YouTubeMusicViewModel) {
        self.viewModel = viewModel
        viewModel.onTrackChange = { [weak self] title, artist, artworkUrl, isPlaying in
            self?.updateNowPlaying(title: title, artist: artist, artworkUrl: artworkUrl, isPlaying: isPlaying)
        }
    }

    private func becomeNowPlaying() {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = "YouTube Music"
        nowPlayingInfo[MPMediaItemPropertyArtist] = ""
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updateNowPlaying(title: String?, artist: String?, artworkUrl: URL?, isPlaying: Bool) {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = title ?? "YouTube Music"
        nowPlayingInfo[MPMediaItemPropertyArtist] = artist ?? ""
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        // Without an explicit playback state macOS may not treat this app as the
        // active Now Playing source, so hardware media keys can land elsewhere.
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        // Only fetch artwork when the URL actually changes. Play/pause re-fires this
        // with the same URL, which previously re-downloaded + re-decoded every time.
        guard let url = artworkUrl, url != lastArtworkUrl else { return }
        lastArtworkUrl = url

        if let cached = artworkCache.object(forKey: url as NSURL) {
            applyArtwork(cached)
            return
        }

        Task.detached {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = NSImage(data: data) {
                    await MainActor.run { [weak self] in
                        self?.artworkCache.setObject(image, forKey: url as NSURL)
                        self?.applyArtwork(image)
                    }
                }
            } catch {}
        }
    }

    private func applyArtwork(_ image: NSImage) {
        currentArtwork = image
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { [weak self] _ in
            return self?.currentArtwork ?? NSImage()
        }
        var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        updatedInfo[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
    }

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.playPause()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.playPause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.playPause()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.nextTrack()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.previousTrack()
            }
            return .success
        }

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
    }
}
