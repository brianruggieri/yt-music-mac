# MilkDrop Visualizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an audio-reactive MilkDrop-style "Visualizer" mode (Butterchurn, in the webview) fed by a native macOS Core Audio process tap, surfaced as a 3rd option on YT Music's Song/Video toggle.

**Architecture:** WebKit plays YT Music audio out-of-process and the webview's audio is unreadable from JS (CORS taint). So audio is captured natively via a Core Audio process tap, pushed into the page (`evaluateJavaScript` → AudioWorklet), and Butterchurn renders it to a `<canvas>` injected into YT's center stage. Two unknowns (capture target, Butterchurn feed wiring) are resolved by Phase-0 spikes before the full build.

**Tech Stack:** Swift / AppKit / WebKit (`WKWebView`, `WKURLSchemeHandler`, `WKScriptMessageHandler`), Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`), Accelerate (optional), Butterchurn + butterchurn-presets (JS/WebGL2, MIT), Web Audio `AudioWorklet`.

**Spec:** `docs/superpowers/specs/2026-06-29-milkdrop-visualizer-design.md` (Codex-reviewed PASS).

## Global Constraints

- **Deployment target stays macOS 14.0**; the Visualizer feature is **runtime-gated to macOS 14.4+** (toggle hidden when unsupported).
- **No new native dependencies**; Butterchurn/presets are vendored JS files (MIT), no SPM packages.
- **Audio bridge runs at ~60 Hz**, not higher (`evaluateJavaScript` call-rate is the perf risk).
- **PCM is stereo** end-to-end (Butterchurn uses L/R); downmix only inside the worklet if a source is mono.
- **Process-tap teardown is mandatory** on every stop: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.
- **Tap + render run only while Visualizer mode is active**; pause on track-pause, window miniaturize, app resign-active, teardown.
- **Audio permission string:** `NSAudioCaptureUsageDescription` must land in the BUILT `Info.plist`. **The `INFOPLIST_KEY_NSAudioCaptureUsageDescription` build setting is silently dropped by Xcode 16** (verified — not in its recognized allowlist). Inject it via a manual partial `youtube-music-player/Info.plist` referenced by `INFOPLIST_FILE` (kept alongside `GENERATE_INFOPLIST_FILE=YES`, which merges). Always verify with `plutil -p` that the key is present in the built app. (Permission has no public request API; it prompts on first tap start — AudioCap reference.)
- **Build/launch via `./run.sh`** (Release build, wipes derived data, `open`s the app). No Co-Authored-By trailers in commits. ASCII-only commit messages (no em dashes).
- **`run.sh` builds Release**, which strips `#if DEBUG`. **All temporary spike/debug triggers must be plain (non-`#if DEBUG`) menu commands**, removed in Task 12. Verification reads via `print(...)` to stdout and/or an on-screen HUD `<div>` (the pattern the audio spike used) — there is no logger setup in this repo.
- **Actor isolation:** the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (verified in `project.pbxproj`). Therefore `AudioTap` must be designed so its **ring buffer and `latestWindow` are `nonisolated` and thread-safe** (the Core Audio IOProc and the feed timer run off the main actor); only lifecycle (`start`/`stop`) is MainActor. Make the ring buffer a `final class` conforming to `@unchecked Sendable`. Any cross-actor hop in the feed timer uses an explicit `nonisolated` closure, not a MainActor-isolated one.
- **PiP is out of v1.**

---

## Phase 0 — De-risking spikes (GATE: do not start Phase 1 until both pass)

### Task 1: Spike A — audio capture target

**Goal:** Determine which process-tap target yields nonzero, music-tracking audio, since WebKit plays media out-of-process. Produces the target decision + a known-good minimal tap.

**Files:**
- Create: `youtube-music-player/Spikes/AudioTapSpike.swift` (temporary; removed in Task 12)

**Interfaces:**
- Produces: a recorded decision — `TAP_TARGET ∈ {hostPID, webkitChildPIDs, systemOutput}` — consumed by Task 3.

- [ ] **Step 1: Add a minimal process-tap probe.** Create `AudioTapSpike.swift` with a function that, given a set of PID(s) (or "system output"), creates a `CATapDescription`, `AudioHardwareCreateProcessTap`, an aggregate device with `kAudioAggregateDeviceTapAutoStartKey: true`, and an IOProc that accumulates RMS over ~1s, then logs it. Follow the `insidegui/AudioCap` reference for exact IOProc/aggregate setup. Translate PIDs with `kAudioHardwarePropertyTranslatePIDToProcessObject`.

- [ ] **Step 2: Enumerate candidate targets.** From the running app, gather: (i) own PID (`ProcessInfo.processInfo.processIdentifier`), (ii) child WebKit processes — find children whose executable contains `com.apple.WebKit` (`WebContent`/`GPU`) by scanning the process tree (`sysctl`/`proc_listchildpids` or shelling `pgrep -P`), (iii) the system default output device tap.

- [ ] **Step 3: Add temporary trigger + permission string.** Add `INFOPLIST_KEY_NSAudioCaptureUsageDescription = "Visualizes the music you're playing."` to Debug+Release build settings (`project.pbxproj`). Wire a **plain (non-`#if DEBUG`)** temporary menu command in `youtube_music_playerApp.swift` `.commands` ("Run Audio Tap Spike") that runs the probe against each candidate and `print`s RMS to stdout.

- [ ] **Step 4: Build, run, measure.** `./run.sh`. Play a track in YT Music. Trigger the spike. Read RMS from stdout (launch the built binary from a terminal to see `print`, or surface RMS in a temporary on-screen HUD `<div>` like the audio spike used).
Expected: **at least one** target reports **RMS that is nonzero during playback and ~0 when paused**.

- [ ] **Step 5: Record the decision.** Write the winning target + RMS numbers into the plan's Task 3 note and into `memory/visualizer-audio-tap-tainted.md`. If only `systemOutput` works, note the cross-app leakage as a v1 limitation.

- [ ] **Step 6: Commit (spike retained until Task 12).**
```bash
git add youtube-music-player/Spikes/AudioTapSpike.swift youtube-music-player.xcodeproj/project.pbxproj
git commit -m "spike: determine Core Audio process-tap target for webview audio"
```

### Task 2: Spike B — Butterchurn feed recipe

**Goal:** Prove an `AudioWorkletNode` emitting stereo PCM drives Butterchurn (reactive audio level + visible animation), and decide `connectAudio` vs direct `AudioProcessor` feed.

**Files:**
- Create: `youtube-music-player/Resources/visualizer/butterchurn.min.js` (vendored)
- Create: `youtube-music-player/Resources/visualizer/butterchurnPresets.min.js` (vendored)
- Create: `youtube-music-player/Spikes/feed-spike.js` (temporary)

**Interfaces:**
- Produces: (a) the working audio-sink recipe (node graph) consumed by Task 6; (b) the **exact exported global names** from the vendored UMD files (typically `window.butterchurn` with `butterchurn.createVisualizer(...)` and `window.butterchurnPresets` with `.getPresets()`), recorded for Tasks 6/7/9 to consume. Do NOT assume capitalization — read the files.

- [ ] **Step 1: Vendor Butterchurn + record globals.** Download `butterchurn` + `butterchurn-presets` UMD builds (MIT) into `Resources/visualizer/`. Record versions in `Resources/visualizer/VERSIONS.txt`. Open the files (or load them and inspect `window`) and write the **exact** global names + the `createVisualizer`/preset-access signatures into `VERSIONS.txt`; Tasks 6/7/9 must use those names verbatim.

- [ ] **Step 2: Write the feed harness.** `feed-spike.js`: create `AudioContext`; build an inline `AudioWorklet` (via a `Blob` URL) that synthesizes a stereo sine sweep; connect worklet → `<global>.createVisualizer(...).connectAudio(worklet)` (use the exact global recorded in Step 1, e.g. `butterchurn`) **and** worklet → `GainNode(gain=0)` → `destination`. Render to a `<canvas>` appended to the page. Log the visualizer's reported audio level each second.

- [ ] **Step 3: Inject + run.** Temporarily inject `butterchurn.min.js`, `butterchurnPresets.min.js`, and `feed-spike.js` as `WKUserScript`s (string injection, document-end) in `YouTubeMusicWebView.swift`. `./run.sh`.
Expected: the canvas animates and the logged audio level is **nonzero and varies** with the sweep.

- [ ] **Step 4: Decide the recipe.** If `connectAudio(worklet)` animates → use it. If not → switch the harness to feed `visualizer.audio`/`AudioProcessor` byte arrays directly and confirm. Record the working recipe (which node wiring, whether the zero-gain sink to `destination` was required) in Task 6's note.

- [ ] **Step 5: Remove the temporary injection** (keep the vendored JS + record). Revert the `WKUserScript` lines added in Step 3.

- [ ] **Step 6: Commit.**
```bash
git add youtube-music-player/Resources/visualizer/ youtube-music-player/Spikes/feed-spike.js
git commit -m "spike: prove AudioWorklet->Butterchurn feed recipe"
```

---

## Phase 1 — Native audio capture

### Task 3: `AudioTap` — production process tap

**Files:**
- Create: `youtube-music-player/AudioTap.swift`
- Test: inline `#if DEBUG` self-check `AudioTap.selfCheck()`

**Interfaces:**
- Consumes: `TAP_TARGET` from Task 1.
- Produces:
  - `final class AudioTap` — **lifecycle (`start`/`stop`) is MainActor; the ring buffer it owns is `nonisolated` and thread-safe** so the off-main IOProc and the feed timer can touch it (repo default isolation is MainActor — see Global Constraints).
  - `static var isSupported: Bool` (macOS 14.4+ and tap symbols available)
  - `func start() throws` / `func stop()`
  - `nonisolated func latestWindow(frames: Int) -> [Float]` — interleaved stereo, newest `frames` frames (zero-padded if not yet filled)

- [ ] **Step 1: Thread-safe SPSC ring buffer + self-check (write first).** Implement a **thread-safe** single-producer/single-consumer float ring buffer as a `final class … @unchecked Sendable` inside `AudioTap.swift` (lock via `os_unfair_lock`; not literally lock-free, but safe for one IOProc writer + one timer reader). Add `static func selfCheck()` that writes a known ramp and asserts `latest` returns the last N interleaved samples in order.
```swift
// AudioTap.swift (excerpt)
final class RingBuffer: @unchecked Sendable {
    private var buf: [Float]; private let cap: Int
    private var writeIdx = 0
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    init(capacity: Int) { cap = capacity; buf = [Float](repeating: 0, count: capacity); lock.initialize(to: .init()) }
    deinit { lock.deinitialize(count: 1); lock.deallocate() }
    func write(_ samples: UnsafeBufferPointer<Float>) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        for s in samples { buf[writeIdx] = s; writeIdx = (writeIdx + 1) % cap }
    }
    func latest(_ n: Int) -> [Float] {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        var out = [Float](repeating: 0, count: n)
        var idx = (writeIdx - n + cap) % cap
        for i in 0..<n { out[i] = buf[idx]; idx = (idx + 1) % cap }
        return out
    }
}
```

- [ ] **Step 2: Run the self-check.** Trigger `AudioTap.selfCheck()` from a plain (non-`#if DEBUG`) temporary menu command (removed in Task 12). `./run.sh`.
Expected: no assertion failure logged.

- [ ] **Step 3: Productionize the tap.** Port the known-good tap from Task 1's spike into `AudioTap` against `TAP_TARGET`: build `CATapDescription`, `AudioHardwareCreateProcessTap`, aggregate device (`kAudioAggregateDeviceTapAutoStartKey: true`), `AudioDeviceCreateIOProcIDWithBlock` whose block downmixes to stereo Float32 and `ring.write(...)`. Implement `isSupported` (gate on `if #available(macOS 14.4, *)` + symbol availability).

- [ ] **Step 4: Implement teardown.** `stop()` must call, in order: `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`, `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`, and null the IDs. Add an idempotent guard so double-stop is safe.

- [ ] **Step 5: RMS acceptance.** Add `static func rmsCheck()` (DEBUG) that `start()`s, sleeps ~1s, reads `latestWindow(frames: 24000)`, logs RMS, `stop()`s. `./run.sh`, play a track, trigger.
Expected: RMS nonzero during playback, ~0 when paused; no leaked aggregate device (re-trigger 5× without error).

- [ ] **Step 6: Commit.**
```bash
git add youtube-music-player/AudioTap.swift
git commit -m "feat: AudioTap Core Audio process tap with stereo ring buffer and teardown"
```

### Task 4: Native bridge — feed loop, message handler, capability flag

**Files:**
- Modify: `youtube-music-player/YouTubeMusicWebView.swift` (Coordinator + makeNSView)

**Interfaces:**
- Consumes: `AudioTap` (Task 3).
- Produces:
  - JS-callable: native injects `window.__ytmVizSupported = <bool>` at document-start.
  - JS→native message `visualizer` with body `{action: "modeOn"|"modeOff"}`.
  - Native→JS: `window.__milkFeed('<base64 stereo Float32LE>')` at ~60 Hz while active.
  - Native→JS status: `window.MilkViz && window.MilkViz.nativeStatus({state, code})` — emitted on tap start success (`{state:"ok"}`) and failure (`{state:"error", code:"audioCaptureDenied"}`), consumed by Task 11. This is the reliable signal distinguishing permission-denied from slow-start/no-audio.

- [ ] **Step 1: Inject capability flag.** In `makeNSView`, add a document-start `WKUserScript`: `window.__ytmVizSupported = \(AudioTap.isSupported ? "true" : "false");` (mirror the existing `__ytmNativeDark` seed pattern).

- [ ] **Step 2: Register the `visualizer` message handler.** `config.userContentController.add(context.coordinator, name: "visualizer")`. Extend `Coordinator.userContentController(_:didReceive:)` to handle `message.name == "visualizer"`.

- [ ] **Step 3: Implement start/stop + feed loop in Coordinator.** Note the **idempotency guard** (repeated `modeOn` must not create a second tap/timer), the **explicit byte-count base64** (the `Data(buffer:)` form is unreliable here), and the **`nativeStatus` callback** on success/denial.
```swift
// in Coordinator
private var audioTap: AudioTap?
private var feedTimer: DispatchSourceTimer?

@MainActor func startVisualizerFeed(_ webView: WKWebView) {
    if audioTap != nil { return }                 // idempotent: already running
    let tap = AudioTap()
    do { try tap.start() }
    catch {
        webView.evaluateJavaScript("window.MilkViz && window.MilkViz.nativeStatus({state:'error',code:'audioCaptureDenied'})")
        return
    }
    audioTap = tap
    webView.evaluateJavaScript("window.MilkViz && window.MilkViz.nativeStatus({state:'ok'})")
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now(), repeating: .milliseconds(16))   // ~60 Hz
    t.setEventHandler { [weak self, weak webView] in
        guard let self, let webView, let tap = self.audioTap else { return }
        let pcm = tap.latestWindow(frames: 2048)                  // interleaved stereo
        guard !pcm.isEmpty else { return }
        let b64 = pcm.withUnsafeBufferPointer { ptr in
            Data(bytes: ptr.baseAddress!, count: ptr.count * MemoryLayout<Float>.stride)
                .base64EncodedString()
        }
        webView.evaluateJavaScript("window.__milkFeed && window.__milkFeed('\(b64)')")
    }
    t.resume(); feedTimer = t
}

@MainActor func stopVisualizerFeed() {
    feedTimer?.cancel(); feedTimer = nil
    audioTap?.stop(); audioTap = nil
}
```

- [ ] **Step 4: Route messages + teardown hook.** On `modeOn` → `startVisualizerFeed(webView)`; on `modeOff` → `stopVisualizerFeed()`. Hold a `weak var webView` on the Coordinator (set in `makeNSView`). Add `static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator)` that calls `stopVisualizerFeed()` and removes the `visualizer` script-message handler, so a torn-down webview can't leave a tap or timer running.

- [ ] **Step 5: Build + smoke test.** `./run.sh`. Temporarily call `startVisualizerFeed` from the plain (non-DEBUG) temp menu command, and inject a one-line page script: `window.__milkFeed = b => console.log('feed', b.length)`.
Expected: console logs base64 payloads ~60x/s while audio plays; triggering `modeOn` twice does not double the rate (idempotency).

- [ ] **Step 6: Commit.**
```bash
git add youtube-music-player/YouTubeMusicWebView.swift youtube-music-player.xcodeproj/project.pbxproj
git commit -m "feat: native visualizer bridge - capability flag, message handler, 60Hz PCM feed"
```

---

## Phase 2 — Webview rendering & integration

### Task 5: Asset delivery via custom URL scheme (CSP-verified)

**Files:**
- Create: `youtube-music-player/Resources/visualizer/pcm-worklet.js`
- Create: `youtube-music-player/Resources/visualizer/visualizer.js` (stub for now — defines `window.MilkViz = {}`)
- Create: `youtube-music-player/Resources/visualizer/preset-list.js` (**empty stub** — `window.__milkPresets = [];` — fleshed out in Task 9; created here so the bootstrap loader doesn't 404/stall before `visualizer.js`)
- Modify: `youtube-music-player/YouTubeMusicWebView.swift` (register `WKURLSchemeHandler`)

**Interfaces:**
- Produces: a **working bootstrap** that loads `butterchurn.min.js`, `butterchurnPresets.min.js`, `preset-list.js` (Task 9), and `visualizer.js` into the `music.youtube.com` page such that **`window.MilkViz` exists** and the worklet module loads. The confirmed mechanism (URL scheme vs `WKUserScript` string injection + `Blob` worklet) is consumed by Tasks 6–9.

- [ ] **Step 1: Confirm bundle inclusion.** Add the `Resources/visualizer/` files. `./run.sh`, then verify they're in the built bundle: `ls "build/Build/Products/Release/YouTube Music.app/Contents/Resources/"` (account for a possible nested `visualizer/` folder if Xcode preserves it). If absent (the synchronized group treated them as compile sources), mark them as resources / add to Copy Bundle Resources in `project.pbxproj`.
Expected: the JS files are present under `Contents/Resources/`.

- [ ] **Step 2: Implement the scheme handler.** Add `class VizSchemeHandler: NSObject, WKURLSchemeHandler` serving `ytmviz://local/<name>` from the bundle with correct MIME (`text/javascript`). Register via `config.setURLSchemeHandler(VizSchemeHandler(), forURLScheme: "ytmviz")`.

- [ ] **Step 3: Implement the bootstrap loader.** In `makeNSView`, add a document-end `WKUserScript` (main frame) that injects, in order, `<script src="ytmviz://local/butterchurn.min.js">`, `…/butterchurnPresets.min.js`, `…/preset-list.js`, `…/visualizer.js` (appended to `document.head`, awaiting each `onload`). `visualizer.js` defines `window.MilkViz`. The worklet is loaded by `visualizer.js` via `audioWorklet.addModule('ytmviz://local/pcm-worklet.js')`.

- [ ] **Step 4: CSP execution probe (not fetch).** Temporarily make `visualizer.js` set `window.__vizScriptLoaded = true` at its top and have the worklet-load log `VIZ addModule OK`/`FAIL`. Add a temp document-end script: `setTimeout(()=>console.log('VIZ boot', !!window.MilkViz, window.__vizScriptLoaded===true), 3000)`. `./run.sh`, open `music.youtube.com`.
Expected: `VIZ boot true true` **and** `VIZ addModule OK`. **If the scripts don't execute (CSP `script-src` blocks the custom scheme):** switch the bootstrap to read each file's contents natively and inject them as `WKUserScript` strings (which run in the page's own context, not subject to `src` directives), and load the worklet from a `Blob` URL built from the injected `pcm-worklet.js` source. Record which mechanism won in `VERSIONS.txt`.

- [ ] **Step 5: Lock the mechanism + remove probes.** Implement the winning loader as the real path; delete the temporary `__vizScriptLoaded`/`VIZ boot` probe lines.

- [ ] **Step 6: Commit.**
```bash
git add youtube-music-player/Resources/visualizer/ youtube-music-player/YouTubeMusicWebView.swift youtube-music-player.xcodeproj/project.pbxproj
git commit -m "feat: visualizer asset delivery (URL scheme, CSP-verified)"
```

### Task 6: `visualizer.js` — audio sink (end-to-end audio into Butterchurn)

**Files:**
- Modify: `youtube-music-player/Resources/visualizer/pcm-worklet.js`
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js`

**Interfaces:**
- Consumes: Task 2 recipe, Task 4 `__milkFeed`, Task 5 loader.
- Produces: `window.__milkFeed(base64)` populated; `MilkViz.audioLevel()` for tests; Butterchurn instance reachable as `MilkViz.viz`.

- [ ] **Step 1: Worklet processor.** `pcm-worklet.js`: an `AudioWorkletProcessor` with an internal stereo ring buffer filled from `port.onmessage` (Float32 interleaved); `process()` writes the next frames to the 2 output channels, silence on underrun.

- [ ] **Step 2: Audio sink wiring (use Task 2 recipe).** In `visualizer.js`: create `AudioContext`; load worklet (scheme or Blob per Task 5); instantiate node; `window.__milkFeed = b64 => { const buf = Uint8Array.from(atob(b64), c=>c.charCodeAt(0)).buffer; node.port.postMessage(new Float32Array(buf), [buf]); }`; deinterleave inside the worklet. Wire `node → Butterchurn` and `node → GainNode(0) → destination` per the recipe.

- [ ] **Step 3: Expose test hooks.** `MilkViz.audioLevel()` returns Butterchurn's current audio level (or analyser RMS).

- [ ] **Step 4: End-to-end check.** Temporarily auto-start the sink + `modeOn`. `./run.sh`, play a track.
Expected: `MilkViz.audioLevel()` (log it) is nonzero and tracks the music.

- [ ] **Step 5: Commit.**
```bash
git add youtube-music-player/Resources/visualizer/
git commit -m "feat: visualizer audio sink - worklet fed by native PCM into Butterchurn"
```

### Task 7: Renderer + canvas + sizing

**Files:**
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js`

**Interfaces:**
- Produces: `MilkViz.mount(container)` / `MilkViz.unmount()`; rAF render loop; `MilkViz.canvas`.

- [ ] **Step 1: Canvas + visualizer.** Create a `<canvas>`, `<global>.createVisualizer(audioCtx, canvas, {width,height,pixelRatio: devicePixelRatio})` using the exact global recorded in Task 2 (e.g. `butterchurn`), connect the audio node (Task 6). `mount(container)` inserts the canvas sized to the container; observe resize (`ResizeObserver`) and call `viz.setRendererSize`.

- [ ] **Step 2: Render loop.** `requestAnimationFrame` loop calling `viz.render()`; `MilkViz.pause()/resume()` control it; guard against WebGL2 unavailability (feature-detect, show a static message div).

- [ ] **Step 3: Visual check.** Temporarily mount over the stage on load. `./run.sh`, play a track.
Expected: animated reactive visuals at the container size; resizes cleanly.

- [ ] **Step 4: Commit.**
```bash
git add youtube-music-player/Resources/visualizer/visualizer.js
git commit -m "feat: Butterchurn renderer, canvas mount, resize handling"
```

### Task 8: Toggle injection + mode lifecycle (with overlay fallback)

**Files:**
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js`

**Interfaces:**
- Consumes: `MilkViz.mount/unmount`, native `__ytmVizSupported`, `visualizer` message channel.
- Produces: `MilkViz.setActive(bool)` → posts `{action}` to native, shows/hides canvas, toggles YT stage.

- [ ] **Step 1: Locate + inject the segment.** `MutationObserver` finds YT's Song/Video segmented control; if `window.__ytmVizSupported`, inject a 3rd "Visualizer" segment styled to match (read sibling classes/computed styles for light/dark). Re-inject on re-render. Gate entirely off if unsupported.

- [ ] **Step 2: Overlay fallback.** If the control isn't found within ~5s, inject an overlaid native-looking "Visualizer" button into the stage area instead.

- [ ] **Step 3: Wire activation.** On select → `MilkViz.setActive(true)`: hide YT player stage, mount canvas in the stage container, `webkit.messageHandlers.visualizer.postMessage({action:'modeOn'})`, `MilkViz.resume()`. On Song/Video select (or toggle off) → `setActive(false)`: unmount, restore stage, `{action:'modeOff'}`, `MilkViz.pause()`.

- [ ] **Step 4: Check.** `./run.sh`, play a track, click Visualizer, click back.
Expected: clean swap both ways; native feed starts/stops (verify via log); segment survives navigation.

- [ ] **Step 5: Commit.**
```bash
git add youtube-music-player/Resources/visualizer/visualizer.js
git commit -m "feat: Visualizer toggle segment with overlay fallback and mode lifecycle"
```

### Task 9: Preset manager

**Files:**
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js`
- Modify: `youtube-music-player/Resources/visualizer/preset-list.js` (created as a stub in Task 5; fill with curated names here)

**Interfaces:**
- Consumes: `MilkViz.viz`; the preset global recorded in Task 2 (e.g. `butterchurnPresets.getPresets()`).
- Produces: auto-cycle + manual skip + name toast.
- **Track-change detection is owned by `visualizer.js` itself** — it runs its **own** observer (a `MutationObserver` on the player title node, or polling `navigator.mediaSession.metadata.title`), NOT a Swift-side signal. The native track observer in `YouTubeMusicWebView.swift` is for Discord/Now-Playing and is not exposed to page JS; do not depend on it.

- [ ] **Step 1: Curate.** Pick ~20–40 preset keys from the recorded preset global (e.g. `butterchurnPresets.getPresets()`) into `preset-list.js`.

- [ ] **Step 2: Cycle logic.** `loadPreset(i, blend=2.7)`; auto-advance every 22s (randomized 18–28s); advance on track change via `visualizer.js`'s own title observer (above); `ArrowLeft/Right` + canvas click to step. Only run timers while active.

- [ ] **Step 3: Toast.** On preset change, show a subtle auto-fading name toast over the canvas.

- [ ] **Step 4: Check.** `./run.sh`, enter Visualizer.
Expected: presets blend ~every 22s, skip on arrows/click, advance on track change, toast shows the name.

- [ ] **Step 5: Commit.**
```bash
git add youtube-music-player/Resources/visualizer/
git commit -m "feat: preset auto-cycle, manual skip, track-change advance, name toast"
```

### Task 10: Fullscreen

**Files:**
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js`

- [ ] **Step 1: Fullscreen control.** Add a fullscreen button over the canvas → `container.requestFullscreen()`; handle `fullscreenchange` to resize the canvas; ESC restores inline.

- [ ] **Step 2: Check.** `./run.sh`, enter Visualizer, toggle fullscreen.
Expected: canvas fills the screen and restores cleanly; audio uninterrupted.

- [ ] **Step 3: Commit.**
```bash
git add youtube-music-player/Resources/visualizer/visualizer.js
git commit -m "feat: visualizer fullscreen"
```

### Task 11: Lifecycle, permission & error states

**Files:**
- Modify: `youtube-music-player/YouTubeMusicWebView.swift`
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js`

**Interfaces:**
- Consumes: existing track-pause signal; AppKit notifications.

- [ ] **Step 1: Native lifecycle pauses.** While mode is active, pause the feed loop (don't tear down the tap) on `NSWindow.didMiniaturizeNotification` and `NSApplication.didResignActiveNotification`; resume on the inverse. Fully `stopVisualizerFeed()` on view/window teardown. Observe the existing track-change observer for pause/play and pause/resume the feed accordingly.

- [ ] **Step 2: Permission-denied UX (driven by `nativeStatus`).** On `tap.start()` failure, native calls `MilkViz.nativeStatus({state:'error',code:'audioCaptureDenied'})` (Task 4) — this is the reliable signal, distinct from slow-start/no-audio. `MilkViz.nativeStatus` shows an in-canvas message ("Audio capture permission needed - System Settings > Privacy & Security > Audio Capture") and runs Butterchurn in a no-audio idle mode (gentle motion). Add a "Try again" affordance that re-posts `modeOn`. Also add a JS fallback: if no `__milkFeed` call and no `nativeStatus` arrives within ~3s of `modeOn`, show a generic "no audio" hint.

- [ ] **Step 3: Unsupported/WebGL2 states.** Confirm the segment is hidden when `__ytmVizSupported===false`; confirm the WebGL2-missing fallback (Task 7) shows.

- [ ] **Step 4: Check.** `./run.sh`: test pause (track + miniaturize + app-switch) stops/resumes the feed (verify via log); revoke audio permission to see the denied state.
Expected: feed quiesces when not needed; permission state is informative, not broken.

- [ ] **Step 5: Commit.**
```bash
git add youtube-music-player/YouTubeMusicWebView.swift youtube-music-player/Resources/visualizer/visualizer.js
git commit -m "feat: visualizer lifecycle pauses, permission and unsupported states"
```

---

## Phase 3 — Cleanup & QA

### Task 12: Remove spikes, final QA, docs

**Files:**
- Delete: `youtube-music-player/Spikes/AudioTapSpike.swift`, `youtube-music-player/Spikes/feed-spike.js`
- Remove: temporary (non-`#if DEBUG`) menu commands / self-check triggers added in Tasks 1-6
- Modify: `README.md` (mention the Visualizer mode), `youtube_music_playerApp.swift` (drop temp commands)

- [ ] **Step 1: Strip spike scaffolding.** Delete the Spikes/ files and any temporary DEBUG menu items / auto-start hooks left from earlier tasks. Keep `AudioTap.selfCheck()`/`rmsCheck()` only if behind `#if DEBUG` and harmless; otherwise remove.

- [ ] **Step 2: Full manual QA pass.** `./run.sh`. Verify end-to-end: toggle appears (14.4+), Visualizer reacts to audio, presets cycle + skip + advance on track change, fullscreen works, switching to Song/Video tears down the tap (RMS→0, no leaked aggregate device across 10 toggles), permission-denied path, app-switch/miniaturize pause.

- [ ] **Step 3: Doc.** Add a short "Visualizer" note to `README.md`.

- [ ] **Step 4: Commit.**
```bash
git add -A
git commit -m "chore: remove visualizer spikes; QA pass; document Visualizer mode"
```

---

## Self-review notes (coverage)

- Spec §5.0 spikes → Tasks 1–2 (gating). §5.1 native tap + teardown + isSupported → Task 3. Bridge/feed/INFOPLIST_KEY → Task 4. Asset delivery + CSP → Task 5. Audio sink (stereo, zero-gain sink) → Task 6. Renderer → Task 7. Toggle + overlay fallback → Task 8. Presets → Task 9. Fullscreen → Task 10. Lifecycle/permission/unsupported/WebGL2 → Task 11. PiP explicitly excluded (spec §10). Cleanup/QA → Task 12.
- Names consistent across tasks: `__milkFeed`, `__ytmVizSupported`, `visualizer` message, `MilkViz.*`, `AudioTap.{isSupported,start,stop,latestWindow}`, `TAP_TARGET`.
- Verification adapted to this repo (no XCTest/pytest): each task ends with a `./run.sh` build + a concrete runtime acceptance check, plus DEBUG self-checks where logic is unit-testable (ring buffer).
