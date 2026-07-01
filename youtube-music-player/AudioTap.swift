//
//  AudioTap.swift
//  youtube-music-player
//
//  Production Core Audio process tap for the MilkDrop visualizer.
//
//  WebKit decodes/plays YT Music audio in an out-of-process child (WebContent /
//  GPU), not this host PID. Phase-0 spikes proved the music rides the app's
//  app-isolated WebKit GPU child and that a process tap on it tracks play/pause
//  exactly. This taps the right child(ren) and exposes a stereo Float32 ring the
//  feed timer drains at 60 Hz via `latestWindow(frames:)`.
//
//  API sequence mirrors the verified spike (see Spikes/SPIKE-RESULTS.md):
//    PID -> AudioObjectID via kAudioHardwarePropertyTranslatePIDToProcessObject
//    CATapDescription(stereoMixdownOfProcesses:) -> AudioHardwareCreateProcessTap
//    aggregate device (kAudioAggregateDeviceTapAutoStartKey: true,
//                      kAudioAggregateDeviceTapListKey -> kAudioSubTapUIDKey)
//    AudioDeviceCreateIOProcIDWithBlock -> AudioDeviceStart
//    teardown: Stop -> DestroyIOProcID -> DestroyAggregateDevice -> DestroyProcessTap
//
//  Target selection: enumerate WebKit GPU/WebContent children, keep only those
//  whose RESPONSIBLE process is our own PID (excludes other apps' WebKit helpers
//  that launchd re-parents), then mix the survivors down to stereo. The GPU child
//  carries the music; silent WebContent children mix down harmlessly.

import CoreAudio
import Foundation
import os

// libsystem private API, stable; used by AudioCap-style process-audio code to
// map a WebKit helper back to the app responsible for it. Returns -1 on failure.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// Thread-safe single-producer (IOProc) / single-consumer (feed timer) float ring.
/// Stores interleaved stereo samples. Locked with `os_unfair_lock` — not lock-free,
/// but correct for one RT-thread writer and one timer reader.
final class RingBuffer: @unchecked Sendable {
    private var buf: [Float]; private let cap: Int
    private var writeIdx = 0
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    init(capacity: Int) { cap = capacity; buf = [Float](repeating: 0, count: capacity); lock.initialize(to: .init()) }
    deinit { lock.deinitialize(count: 1); lock.deallocate() }
    // Monotonic sample counters for the draining reader (the feed). writeCount tracks total
    // samples ever written; readCount tracks total drained. available = writeCount - readCount.
    private var writeCount = 0
    private var readCount = 0
    func write(_ samples: UnsafeBufferPointer<Float>) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        for s in samples { buf[writeIdx] = s; writeIdx = (writeIdx + 1) % cap }
        writeCount += samples.count
    }
    func latest(_ n: Int) -> [Float] {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        var out = [Float](repeating: 0, count: n)
        var idx = (writeIdx - n + cap) % cap
        for i in 0..<n { out[i] = buf[idx]; idx = (idx + 1) % cap }
        return out
    }
    // Draining read: returns only samples written since the previous drain (capped at
    // maxSamples), advancing the read cursor. Unlike latest(), consecutive drains never
    // overlap — so the 60 Hz feed sends ~one tick of fresh audio instead of a sliding
    // window that floods the worklet. On overflow (writer lapped the reader) the oldest
    // unread samples are dropped.
    func drain(_ maxSamples: Int) -> [Float] {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        var avail = writeCount - readCount
        if avail > cap { readCount = writeCount - cap; avail = cap }   // dropped oldest unread
        let n = min(avail, maxSamples)
        if n <= 0 { return [] }
        var out = [Float](repeating: 0, count: n)
        var idx = readCount % cap
        for i in 0..<n { out[i] = buf[idx]; idx = (idx + 1) % cap }
        readCount += n
        return out
    }
}

final class AudioTap {

    struct AudioTapError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // ~1s of stereo @ 48 kHz. Covers the largest read (rmsCheck reads 24000 frames
    // == 48000 samples); the 60 Hz feed reads far less.
    private static let ringCapacity = 96_000

    private let unknown = AudioObjectID(kAudioObjectUnknown)

    /// Owned ring. `nonisolated let` of a Sendable type so the off-main IOProc and
    /// the (nonisolated) `latestWindow` reader can touch it without the MainActor.
    nonisolated let ring = RingBuffer(capacity: AudioTap.ringCapacity)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// macOS 14.4+ is required for Core Audio process taps (CATapDescription,
    /// AudioHardwareCreateProcessTap). Below that the feature is unavailable.
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    // MARK: Lifecycle (MainActor)

    /// Build a fresh tap over the current WebKit children and start it.
    /// No-op if already running. Rebuilt each start because WebContent children
    /// can be replaced on reload.
    func start() throws {
        guard #available(macOS 14.4, *) else {
            throw AudioTapError("Core Audio process taps require macOS 14.4+")
        }
        guard aggID == unknown else { return }   // guard double-start

        do {
            try buildTap()
        } catch {
            stop()   // tear down anything partially created
            throw error
        }
    }

    /// Idempotent teardown in the mandated order. Safe to call twice; leaks nothing.
    /// Nothing is ever created below macOS 14.4, so the tap teardown is gated and is
    /// a no-op on older systems (the IDs stay `unknown`).
    func stop() {
        guard #available(macOS 14.4, *) else { return }
        if let procID, aggID != unknown {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        if aggID != unknown { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != unknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggID = unknown
        tapID = unknown
    }

    @available(macOS 14.4, *)
    private func buildTap() throws {
        // 1. Resolve our WebKit children to Core Audio process objects.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let kids = Self.webKitChildPIDs(of: ownPID)
        let objects = kids.compactMap { try? Self.translatePIDToProcessObject($0) }
        guard !objects.isEmpty else {
            throw AudioTapError("No WebKit audio process found (is a track loaded?)")
        }

        // 2. Stereo mixdown tap over the survivors.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: objects)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted   // keep the music audible

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard err == noErr, newTapID != unknown else {
            throw AudioTapError("AudioHardwareCreateProcessTap failed: \(err)")
        }
        tapID = newTapID

        // 3. Private, auto-starting aggregate device wrapping the tap.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MilkDropTapAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString]
            ],
        ]
        var newAggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggID)
        guard err == noErr, newAggID != unknown else {
            throw AudioTapError("AudioHardwareCreateAggregateDevice failed: \(err)")
        }
        aggID = newAggID

        // 4. IOProc: downmix whatever layout we get to interleaved stereo Float32,
        //    then write into the ring. Runs on a Core Audio RT thread — capture only
        //    the Sendable `ring`, never `self` (MainActor).
        let ring = self.ring
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard abl.count > 0 else { return }

            if abl.count >= 2 {
                // Deinterleaved/planar: buffer 0 = L, buffer 1 = R.
                guard let lp = abl[0].mData, let rp = abl[1].mData else { return }
                let lf = lp.assumingMemoryBound(to: Float32.self)
                let rf = rp.assumingMemoryBound(to: Float32.self)
                let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float32>.size
                withUnsafeTemporaryAllocation(of: Float.self, capacity: frames * 2) { tmp in
                    for i in 0..<frames { tmp[2 * i] = lf[i]; tmp[2 * i + 1] = rf[i] }
                    ring.write(UnsafeBufferPointer(tmp))
                }
                return
            }

            // Single interleaved buffer.
            let buffer = abl[0]
            guard let mData = buffer.mData else { return }
            let f = mData.assumingMemoryBound(to: Float32.self)
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let ch = max(1, Int(buffer.mNumberChannels))
            if ch == 2 {
                ring.write(UnsafeBufferPointer(start: f, count: total))   // already stereo
            } else if ch == 1 {
                withUnsafeTemporaryAllocation(of: Float.self, capacity: total * 2) { tmp in
                    for i in 0..<total { tmp[2 * i] = f[i]; tmp[2 * i + 1] = f[i] }
                    ring.write(UnsafeBufferPointer(tmp))
                }
            } else {
                // N>2 interleaved: take the first two channels as L/R.
                let frames = total / ch
                withUnsafeTemporaryAllocation(of: Float.self, capacity: frames * 2) { tmp in
                    for i in 0..<frames { tmp[2 * i] = f[i * ch]; tmp[2 * i + 1] = f[i * ch + 1] }
                    ring.write(UnsafeBufferPointer(tmp))
                }
            }
        }

        var newProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggID, nil, ioBlock)
        guard err == noErr, let newProcID else {
            throw AudioTapError("AudioDeviceCreateIOProcIDWithBlock failed: \(err)")
        }
        procID = newProcID

        // 5. Start. The aggregate auto-starts the tap; this starts the IOProc.
        err = AudioDeviceStart(aggID, newProcID)
        guard err == noErr else {
            throw AudioTapError("AudioDeviceStart failed: \(err)")
        }
    }

    // MARK: Reader (nonisolated, thread-safe)

    /// Newest `frames` stereo sample-frames as interleaved Float32 (L,R,L,R…),
    /// i.e. `frames * 2` values, zero-padded at the front if not yet filled.
    nonisolated func latestWindow(frames: Int) -> [Float] {
        ring.latest(frames * 2)
    }

    /// Drains only the stereo frames captured since the previous call (up to `maxFrames`),
    /// as interleaved Float32. Consecutive calls don't overlap — the 60 Hz feed uses this so
    /// it sends one tick of fresh audio (~real-time) instead of a sliding window that floods
    /// the worklet ring. Returns [] when nothing new has been captured.
    nonisolated func drainNew(maxFrames: Int) -> [Float] {
        ring.drain(maxFrames * 2)
    }

    // MARK: Target discovery

    /// Translate a Unix pid to a Core Audio process AudioObjectID.
    @available(macOS 14.4, *)
    private static func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &qualifier,
            &dataSize,
            &objectID)
        guard err == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioTapError("No audio process object for pid \(pid) (err \(err))")
        }
        return objectID
    }

    /// WebKit GPU/WebContent children whose RESPONSIBLE process is our own PID.
    /// The responsible-PID filter is load-bearing: WebKit re-parents helpers under
    /// launchd, so ancestry tracing leaks other apps' helpers — responsibility maps
    /// each helper back to the app that owns it.
    private static func webKitChildPIDs(of ownPID: pid_t) -> [pid_t] {
        guard let out = runPS() else { return [] }
        var result: [pid_t] = []
        for line in out.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = pid_t(parts[0]) else { continue }
            let comm = String(parts[2])
            guard comm.contains("com.apple.WebKit"),
                  comm.contains("WebContent") || comm.contains("GPU") else { continue }
            if responsibility_get_pid_responsible_for_pid(pid) == ownPID {
                result.append(pid)
            }
        }
        return result.sorted()
    }

    /// `ps -axo pid=,ppid=,comm=` -> "  1234  5678 /path/to/exe".
    private static func runPS() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: Debug self-checks (stripped from Release; kept for debugging)

    #if DEBUG
    /// Pure ring-buffer logic check — no audio. Mirrors scratchpad/ringcheck.swift.
    nonisolated static func selfCheck() {
        setvbuf(stdout, nil, _IONBF, 0)
        let rb = RingBuffer(capacity: 8)
        (1...10).map(Float.init).withUnsafeBufferPointer { rb.write($0) }
        let out = rb.latest(4)
        assert(out == [7, 8, 9, 10], "selfCheck: expected [7,8,9,10], got \(out)")

        let rb2 = RingBuffer(capacity: 8)
        [Float(3), 4].withUnsafeBufferPointer { rb2.write($0) }
        let out2 = rb2.latest(4)
        assert(out2 == [0, 0, 3, 4], "selfCheck: expected [0,0,3,4], got \(out2)")
        print("[AudioTap] selfCheck PASSED (out=\(out), padded=\(out2))")
    }

    /// Live-audio acceptance: start, sample ~1s, log RMS, stop. RMS should be
    /// nonzero during playback and ~0 when paused. Re-run 5x to confirm no leaked
    /// aggregate device. REQUIRES a human playing a track — cannot self-verify.
    /// Runs on the MainActor; the ~1s sleep blocks the UI but not the Core Audio
    /// RT thread, so the ring still fills.
    static func rmsCheck() {
        setvbuf(stdout, nil, _IONBF, 0)
        print("===== AudioTap RMS CHECK =====")
        guard isSupported else {
            print("[AudioTap] rmsCheck: unsupported OS (<14.4)")
            print("===== END RMS CHECK =====")
            return
        }
        let tap = AudioTap()
        do {
            try tap.start()
        } catch {
            print("[AudioTap] rmsCheck: start failed: \(error)")
            print("===== END RMS CHECK =====")
            return
        }
        Thread.sleep(forTimeInterval: 1.0)
        let window = tap.latestWindow(frames: 24_000)   // 48000 interleaved samples
        var sumSquares = 0.0
        for v in window { sumSquares += Double(v) * Double(v) }
        let rms = window.isEmpty ? 0 : (sumSquares / Double(window.count)).squareRoot()
        print(String(format: "[AudioTap] RMS = %.6f (samples=%d)", rms, window.count))
        tap.stop()
        print("[AudioTap] NOTE: nonzero only counts if it drops to ~0 when PAUSED.")
        print("===== END RMS CHECK =====")
    }
    #endif
}
