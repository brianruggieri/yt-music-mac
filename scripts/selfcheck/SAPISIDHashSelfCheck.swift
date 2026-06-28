import Foundation

@main
struct SAPISIDHashSelfCheck {
    static func main() {
        // Known-answer test: sha1("1 SAPISID_TEST https://music.youtube.com") hex,
        // prefixed by "SAPISIDHASH 1_". Compute the expected sha1 with the same recipe.
        let out = SAPISIDHash.authorization(sapisid: "SAPISID_TEST", origin: "https://music.youtube.com", timestamp: 1)
        assert(out.hasPrefix("SAPISIDHASH 1_"), "prefix wrong: \(out)")
        let hex = String(out.dropFirst("SAPISIDHASH 1_".count))
        assert(hex.count == 40, "sha1 hex must be 40 chars, got \(hex.count): \(hex)")
        assert(hex.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }, "lowercase hex expected")
        // Stability: same inputs → same output
        assert(out == SAPISIDHash.authorization(sapisid: "SAPISID_TEST", origin: "https://music.youtube.com", timestamp: 1))
        // Golden-answer: pin the exact digest for known inputs to catch payload-order
        // regressions (e.g. "sapisid ts origin" instead of "ts sapisid origin").
        // Expected: sha1("1 SAPISID_TEST https://music.youtube.com") = 4f4b06524015ec0ceb1573e0d9c62a8ac761d9a2
        assert(out == "SAPISIDHASH 1_4f4b06524015ec0ceb1573e0d9c62a8ac761d9a2",
               "golden vector mismatch — payload order regression? got: \(out)")
        print("SAPISIDHash self-check PASS")
    }
}
