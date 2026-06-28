import Foundation

@MainActor
class DiscordRPC {
    private let clientId = Secrets.discordClientId

    private var socket: Int32 = -1
    private var isConnected = false

    // Track identity + start time so the Discord "elapsed" timestamp stays stable
    // for the current song instead of resetting on every updatePresence call.
    private var lastTrackKey = ""
    private var trackStartMs = 0

    init() {
        connect()
    }

    deinit {
        if socket >= 0 {
            Darwin.close(socket)
        }
    }

    func connect() {
        guard !isConnected else { return }

        var socketPaths = ["/tmp/discord-ipc-0", "/var/tmp/discord-ipc-0"]

        // The Discord socket normally lives in the Darwin per-user temp dir, which
        // confstr returns directly. The old fallback crawled all of /var/folders
        // on the main thread to find it — slow and pointless given this lookup.
        var buffer = [CChar](repeating: 0, count: 1024)
        confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let darwinTmp = String(cString: buffer)
        if !darwinTmp.isEmpty {
            socketPaths.insert("\(darwinTmp)discord-ipc-0", at: 0)
        }

        for path in socketPaths {
            socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            if socket < 0 { continue }

            // Without SO_NOSIGPIPE, writing to a socket Discord has closed raises
            // SIGPIPE, which by default kills the whole app before send()'s return
            // value can be inspected. Suppress it so writes fail with EPIPE instead.
            var nosigpipe: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)

            let pathBytes = path.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { sunPath in
                    for (i, byte) in pathBytes.enumerated() where i < 104 {
                        sunPath[i] = byte
                    }
                }
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.connect(socket, sockaddrPtr, addrLen)
                }
            }

            if result == 0 {
                isConnected = true
                handshake()
                return
            } else {
                Darwin.close(socket)
            }
        }
    }

    private func handshake() {
        let payload: [String: Any] = [
            "v": 1,
            "client_id": clientId
        ]

        send(opcode: 0, payload: payload)

        let sock = socket
        Task.detached {
            Self.readResponse(socket: sock)
        }
    }

    nonisolated private static func readResponse(socket: Int32) {
        var header = [UInt8](repeating: 0, count: 8)
        let headerRead = Darwin.recv(socket, &header, 8, 0)

        if headerRead == 8 {
            let length = Int(header[4]) | (Int(header[5]) << 8) | (Int(header[6]) << 16) | (Int(header[7]) << 24)
            var body = [UInt8](repeating: 0, count: length)
            _ = Darwin.recv(socket, &body, length, 0)
        }
    }

    func updatePresence(title: String, artist: String, artworkUrl: String?) {
        if !isConnected {
            connect()
        }
        guard isConnected else { return }

        var assets: [String: Any] = [:]
        if let artwork = artworkUrl, !artwork.isEmpty {
            assets["large_image"] = artwork
            assets["large_text"] = title
        }

        // Only reset the start timestamp when the track actually changes; otherwise
        // re-sending presence (play/pause, poller) would keep restarting elapsed.
        let trackKey = "\(title)\u{0}\(artist)"
        if trackKey != lastTrackKey {
            lastTrackKey = trackKey
            trackStartMs = Int(Date().timeIntervalSince1970 * 1000)
        }

        let activity: [String: Any] = [
            "details": title,
            "state": "by \(artist)",
            "timestamps": [
                "start": trackStartMs
            ],
            "assets": assets
        ]

        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "activity": activity
            ],
            "nonce": UUID().uuidString
        ]

        send(opcode: 1, payload: payload)
    }

    func clearPresence() {
        guard isConnected else { return }

        // Forget the current track so resuming it later recomputes a fresh start
        // time instead of showing elapsed time accrued across the stopped interval.
        lastTrackKey = ""
        trackStartMs = 0

        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "activity": NSNull()
            ],
            "nonce": UUID().uuidString
        ]

        send(opcode: 1, payload: payload)
    }

    private func send(opcode: UInt32, payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }

        let length = UInt32(jsonData.count)
        var header = [UInt8](repeating: 0, count: 8)

        header[0] = UInt8(opcode & 0xFF)
        header[1] = UInt8((opcode >> 8) & 0xFF)
        header[2] = UInt8((opcode >> 16) & 0xFF)
        header[3] = UInt8((opcode >> 24) & 0xFF)

        header[4] = UInt8(length & 0xFF)
        header[5] = UInt8((length >> 8) & 0xFF)
        header[6] = UInt8((length >> 16) & 0xFF)
        header[7] = UInt8((length >> 24) & 0xFF)

        var message = header
        message.append(contentsOf: jsonData)

        // send() on a stream socket may write fewer bytes than requested; a partial
        // write would leave Discord with a truncated, misframed IPC packet. Loop until
        // the whole frame is out, and tear down on any error so the next
        // updatePresence reconnects instead of writing to a dead fd forever.
        var total = 0
        message.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while total < message.count {
                let n = Darwin.send(socket, base + total, message.count - total, 0)
                if n <= 0 {
                    disconnect()
                    return
                }
                total += n
            }
        }
    }

    func disconnect() {
        if socket >= 0 {
            Darwin.close(socket)
            socket = -1
        }
        isConnected = false
    }
}
