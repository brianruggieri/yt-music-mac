import Foundation

enum SpotifyConfig {
    static let clientID = Secrets.spotifyClientID
    static let redirectURI = "ytmusic-import://callback"
    static let scopes = ["playlist-read-private", "playlist-read-collaborative", "user-library-read"]
    static let authBase = "https://accounts.spotify.com"
    static let apiBase = "https://api.spotify.com/v1"
}
