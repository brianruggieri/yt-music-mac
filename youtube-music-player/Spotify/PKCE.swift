import Foundation
import CryptoKit
import Security  // SecRandomCopyBytes / kSecRandomDefault / errSecSuccess

/// RFC 7636 PKCE helpers — pure functions, no app state.
enum PKCE {
    /// Generates a cryptographically random code verifier (64 random bytes → base64url, ~86 chars).
    /// Length is within the 43–128 range required by RFC 7636.
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // Fail-closed: a zero-filled buffer would yield a deterministic verifier,
        // which is a security failure. RNG failure is unrecoverable — trap.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return Data(bytes).base64URLEncoded
    }

    /// Returns the S256 code challenge: base64url(SHA-256(verifier)).
    static func challenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded
    }
}

private extension Data {
    /// Standard base64 → base64url (RFC 4648 §5): replace +/→-_, strip =.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
