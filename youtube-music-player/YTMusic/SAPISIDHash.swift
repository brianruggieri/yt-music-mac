import Foundation
import CryptoKit

enum SAPISIDHash {
    static func authorization(sapisid: String, origin: String, timestamp: Int) -> String {
        let payload = "\(timestamp) \(sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }
}
