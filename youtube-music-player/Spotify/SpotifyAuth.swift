import Foundation
import AuthenticationServices
import AppKit

// ponytail: SpotifyAuth is implicitly @MainActor via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor build
// setting, matching every other type in the project.

/// Spotify OAuth via Authorization Code + PKCE (RFC 7636). No client secret required.
///
/// URL-scheme registration note:
///   ASWebAuthenticationSession accepts an explicit callbackURLScheme ("ytmusic-import") which on
///   macOS is sufficient for the callback to be intercepted — no Info.plist CFBundleURLTypes entry
///   is needed at runtime. Adding one is defensive/optional and requires a pbxproj edit since this
///   target uses GENERATE_INFOPLIST_FILE=YES (CFBundleURLTypes is an array and cannot be expressed
///   as a single INFOPLIST_KEY_* setting). See task-5-report.md for the exact change needed if
///   registration is required for a future macOS release.
final class SpotifyAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SpotifyAuth()
    private override init() {}

    // Strong reference required by ARC — ASWebAuthenticationSession must outlive the callback.
    private var authSession: ASWebAuthenticationSession?

    /// True if a token blob is persisted in the Keychain.
    var isConnected: Bool {
        (try? KeychainStore.load()) != nil
    }

    // MARK: - Public API

    /// Opens the Spotify authorization page, exchanges the code for tokens, stores them in
    /// the Keychain, and returns the fresh access token.
    func authorize() async throws -> String {
        let verifier = PKCE.verifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = UUID().uuidString

        var comps = URLComponents(string: "\(SpotifyConfig.authBase)/authorize")!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id",      value: SpotifyConfig.clientID),
            .init(name: "redirect_uri",   value: SpotifyConfig.redirectURI),
            .init(name: "scope",          value: SpotifyConfig.scopes.joined(separator: " ")),
            .init(name: "code_challenge",        value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state",          value: state),
        ]
        let authURL = comps.url!

        let code = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "ytmusic-import" // intercepts ytmusic-import://callback?code=…
            ) { [weak self] callbackURL, error in
                self?.authSession = nil
                if let error {
                    cont.resume(throwing: SpotifyAuthError.sessionError(error))
                    return
                }
                guard
                    let callbackURL,
                    let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                    let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value,
                    returnedState == state,
                    let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    cont.resume(throwing: SpotifyAuthError.invalidCallback)
                    return
                }
                cont.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            session.start()
        }

        return try await exchange(code: code, verifier: verifier)
    }

    /// Returns a valid access token. Refreshes silently if expired; throws `needsReauth` if
    /// no refresh token is available (user must call `authorize()` again).
    func validAccessToken() async throws -> String {
        let blob: TokenBlob
        do {
            blob = try KeychainStore.load()
        } catch {
            // notFound = not yet connected; any other keychain error = treat as needing reauth.
            throw SpotifyAuthError.needsReauth
        }
        // Give a 60-second buffer before the actual expiry.
        if blob.expiresAt > Date().addingTimeInterval(60) {
            return blob.accessToken
        }
        guard let refreshToken = blob.refreshToken else {
            throw SpotifyAuthError.needsReauth
        }
        do {
            return try await refresh(refreshToken: refreshToken)
        } catch {
            throw SpotifyAuthError.needsReauth
        }
    }

    /// Removes stored tokens from the Keychain.
    func disconnect() {
        KeychainStore.delete()
    }

    // MARK: - Token exchange / refresh

    private func exchange(code: String, verifier: String) async throws -> String {
        let body: [String: String] = [
            "grant_type":    "authorization_code",
            "code":          code,
            "redirect_uri":  SpotifyConfig.redirectURI,   // must match exactly
            "client_id":     SpotifyConfig.clientID,
            "code_verifier": verifier,
        ]
        return try await tokenRequest(body: body)
    }

    private func refresh(refreshToken: String) async throws -> String {
        let body: [String: String] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     SpotifyConfig.clientID,
        ]
        return try await tokenRequest(body: body, existingRefreshToken: refreshToken)
    }

    private func tokenRequest(
        body: [String: String],
        existingRefreshToken: String? = nil
    ) async throws -> String {
        var req = URLRequest(url: URL(string: "\(SpotifyConfig.authBase)/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // ponytail: subtract =&+ so those chars in values can't break the form-encoded body.
        let formSafe = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "=&+"))
        req.httpBody = body
            .map { k, v in
                let ek = k.addingPercentEncoding(withAllowedCharacters: formSafe) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: formSafe) ?? v
                return "\(ek)=\(ev)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw SpotifyAuthError.tokenRequestFailed(http.statusCode, body)
        }
        let tokenResp = try JSONDecoder().decode(TokenResponse.self, from: data)
        let blob = TokenBlob(
            accessToken:  tokenResp.access_token,
            refreshToken: tokenResp.refresh_token ?? existingRefreshToken,
            expiresAt:    Date().addingTimeInterval(Double(tokenResp.expires_in))
        )
        try KeychainStore.save(blob)
        return blob.accessToken
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
    }
}

// MARK: - Supporting types

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
}

enum SpotifyAuthError: Error {
    case sessionError(Error)
    case invalidCallback
    case needsReauth
    case tokenRequestFailed(Int, String)
}
