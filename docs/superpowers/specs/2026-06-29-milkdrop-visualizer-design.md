# MilkDrop Visualizer — Design Spec

**Date:** 2026-06-29
**Status:** Codex review PASS (2 rounds) — ready for implementation planning
**Branch:** `brianruggieri/milkdrop`

## 1. Goal

Add a **"Visualizer"** mode to the YouTube Music macOS app: a real-time, audio-reactive
MilkDrop-style visualizer that reacts to whatever is currently playing. It appears as a
**third option** on YT Music's in-page **Song / Video** segmented control and renders in the
**same center-stage container**. **v1 affordances: inline + fullscreen.** Picture-in-picture is
deferred (see §5.2.6 / §10).

## 2. Background & constraints (established by research + a live spike)

- The app wraps `https://music.youtube.com` in a `WKWebView` (`YouTubeMusicWebView.swift`) and
  already injects multiple `WKUserScript`s + uses `WKScriptMessageHandler` for track/theme data.
  The integration point is `YouTubeMusicWebView.Coordinator`, which already owns script messages.
- **Audio cannot be read from inside the webview.** Confirmed by an injected spike on the live
  app: `createMediaElementSource` + `AnalyserNode` returns **all zeros** (WebKit CORS taint on
  YT's cross-origin media); `HTMLMediaElement.captureStream()` is **not implemented** in WebKit.
  YT Music plays via MSE→`<video>` with **no page-owned Web Audio graph** to tap.
- **WebKit plays media out-of-process.** Decoding/playback happens in WebKit child processes
  (GPUProcess / WebContent), **not** the Swift host PID. This directly shapes the capture target
  (see §5.1) — a tap on the host PID alone would capture silence.
- The only pure-webview alternative (intercept MSE segments → WebCodecs `AudioDecoder`) requires
  **macOS 26+** (dev machine is 14.6) and a hand-written demuxer — rejected.
- **Decision:** capture audio **natively** via a **Core Audio process tap**, and feed PCM into the
  webview where Butterchurn renders.
- See `memory/visualizer-audio-tap-tainted.md` for the full finding.

## 3. Decisions (locked)

| Decision | Choice |
|---|---|
| Renderer | **Butterchurn** (WebGL2, MIT) in an injected `<canvas>` |
| Audio capture | **Native Core Audio process tap** (macOS 14.4+); **target determined by Phase-0 spike** (§5.1) — app's WebKit child processes, else system-output fallback. One-time permission. |
| Audio → webview | Native pulls recent **stereo** PCM window → `evaluateJavaScript` (~60 Hz) → AudioWorklet → Butterchurn (worklet also pathed to a **zero-gain sink → destination** to keep the graph live) |
| Placement | Inline, in YT's center-stage container, as a 3rd toggle segment (with overlay-button fallback) |
| Affordances (v1) | Inline + Fullscreen. **PiP deferred** to a fast-follow, gated on a spike. |
| Presets | Curated pack (~20–40). Auto-blend ~20–30s; advance on track change; click/←→ to skip; subtle name toast |
| Deployment target | Stays **macOS 14.0**; the Visualizer feature is **runtime-gated to 14.4+** (toggle hidden below 14.4) |

## 4. Architecture & data flow

```
YT Music audio plays in a WebKit child process (GPU/WebContent) → system output
        │
   [Native] Core Audio process tap on the audio-producing process object(s)  ← target via §5.1 spike
        │   → ring buffer (stereo Float32)
        │   feed loop (~60 Hz) pulls latest ~2048-frame window while mode active
        ▼   webView.evaluateJavaScript("window.__milkFeed('<base64 stereo Float32LE>')")
   [Webview JS] __milkFeed → post PCM to AudioWorklet
        │     worklet emits stereo PCM → (a) into Butterchurn's audio input
        │                              → (b) zero-gain GainNode → destination  (keeps graph pulled)
        ▼
   Butterchurn renders current preset → <canvas>
```

Native does the one thing the webview cannot (tap audio). Everything visible — canvas, the
injected toggle segment, preset cycling, fullscreen — lives in injected JS.

## 5. Components

### 5.0 Phase 0 — de-risking spikes (build these FIRST, before the full feature)

Two assumptions are implementation-shaping and unproven; each gets a throwaway spike with an
explicit acceptance test. **Do not build the full native tap or full JS integration until both pass.**

- **Spike A — capture target.** With YT Music playing in the app's WKWebView, stand up a minimal
  Core Audio process tap and measure RMS for: (i) the host app PID, (ii) the app's WebKit child
  process(es) (GPUProcess/WebContent, discovered via the process tree), (iii) a system-output tap.
  **Acceptance:** identify a target that yields **nonzero RMS that tracks the music** (goes quiet on
  pause). Record which target works; that decision feeds §5.1. If only the system-output tap works,
  accept its leakage for v1 and note it.
- **Spike B — Butterchurn feed.** In an injected JS harness (no native audio yet — drive with an
  oscillator or synthetic PCM), prove that an `AudioWorkletNode` emitting stereo PCM, connected to
  Butterchurn **and** to a zero-gain sink → `destination`, produces a **nonzero, reactive**
  Butterchurn audio level and visibly animates. Confirm whether `connectAudio(workletNode)` suffices
  or whether we must feed Butterchurn's `AudioProcessor` byte arrays directly. Record the working
  recipe; that decision feeds §5.2.1.

### 5.1 Native (Swift)

**`AudioTap.swift`** (new) — Core Audio process tap.
- Target: the audio-producing process object(s) chosen by **Spike A**. Translate PID(s) →
  CoreAudio process objects (`kAudioHardwarePropertyTranslatePIDToProcessObject`); build a
  `CATapDescription` over them → `AudioHardwareCreateProcessTap` → wrap in an aggregate device
  (`AudioHardwareCreateAggregateDevice`, `kAudioAggregateDeviceTapAutoStartKey: true`) →
  `AudioDeviceCreateIOProcIDWithBlock` IOProc copies **stereo** PCM into a lock-free ring buffer.
- Does **not** use `AVAudioEngine` (cannot retarget onto the tap's aggregate device — read the
  IOProc directly). Reference structure: `insidegui/AudioCap`.
- Public API: `start()`, `stop()`, `latestWindow(frames:) -> [Float]` (interleaved stereo) or fills
  a caller buffer.
- **Teardown is mandatory and explicit** on `stop()` / mode-off / dealloc, in order:
  `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` →
  `AudioHardwareDestroyProcessTap`. Leaking private aggregate devices across mode toggles must not
  happen.
- **Capability gate:** expose a static `isSupported` (macOS 14.4+ and tap APIs present); surfaced
  to JS via an injected flag (mirroring the existing `__ytmNativeDark` seed) so the toggle is hidden
  when unsupported.

**Feed loop + message handler** (in `YouTubeMusicWebView.swift` Coordinator/ViewModel).
- A `visualizer` `WKScriptMessageHandler`: JS posts `{action: "modeOn"|"modeOff"}`. `modeOn`
  starts the tap (triggering the TCC permission prompt on first use) + starts the feed loop;
  `modeOff` stops and tears both down.
- Feed loop (`CVDisplayLink` or a ~60 Hz `DispatchSourceTimer`): pulls the latest stereo window,
  base64-encodes the Float32 little-endian bytes, calls
  `webView.evaluateJavaScript("window.__milkFeed?.('…')")`. **60 Hz, not 90** — `evaluateJavaScript`
  call frequency is the perf risk, not bandwidth.

**Build settings (NOT an Info.plist file — project uses `GENERATE_INFOPLIST_FILE=YES`)**
- Add `INFOPLIST_KEY_NSAudioCaptureUsageDescription = "…"` to **Debug and Release** build settings.
- Binary is already ad-hoc signed by `run.sh`; sandbox is off, which is compatible with process taps.

### 5.2 Webview (JS)

**Asset delivery (default = bundle resources via a custom URL scheme, not giant `WKUserScript`
strings).** Register a `WKURLSchemeHandler` (e.g. `ytmviz://`) that serves the vendored JS from the
app bundle, and load Butterchurn/presets/worklet/visualizer from it. Fall back to `WKUserScript`
string injection only if a quick test shows scheme loading is problematic. Vendored, all MIT:
`butterchurn.min.js`, `butterchurnPresets.min.js`, `pcm-worklet.js`, `visualizer.js`.
- **CSP caveat (test early):** music.youtube.com ships a strict Content-Security-Policy.
  `AudioWorklet.addModule("ytmviz://…/pcm-worklet.js")` and any cross-scheme `<script>`/`fetch` may
  be blocked by the page's `script-src`/`worker-src`. The asset-delivery quick test must explicitly
  verify worklet `addModule` and script loading succeed **under YT Music's CSP** (not on a blank
  page). If CSP blocks the custom scheme, fall back to `WKUserScript` string injection (which runs
  in the page's own context and is not subject to `src` directives), and inline the worklet via a
  `Blob` URL.

**`visualizer.js`** responsibilities:
1. **Audio sink** (recipe finalized by Spike B): `AudioContext`; `audioWorklet.addModule(pcm-worklet)`;
   instantiate the worklet node; expose `window.__milkFeed(base64)` → decode → `port.postMessage`
   (transfer the `Float32Array` buffer). Worklet keeps an internal ring buffer, emits **stereo**
   (duplicate if source is mono), silence on underrun. Connect worklet → Butterchurn input **and**
   worklet → zero-gain `GainNode` → `destination` so the graph is actually pulled. (If Spike B shows
   `connectAudio` insufficient, feed Butterchurn's `AudioProcessor` byte arrays instead.)
2. **Renderer**: create the Butterchurn visualizer on a `<canvas>` sized to the container; drive with
   `requestAnimationFrame`; handle devicePixelRatio + resize.
3. **Toggle injection (with fallback)**: a `MutationObserver` locates YT's Song/Video segmented
   control and injects a styled **"Visualizer"** segment that survives YT's SPA re-renders (same
   pattern as the existing theme/track observers). **Fallback:** if the control isn't found within a
   timeout, show an overlaid, native-looking "Visualizer" button in the stage area rather than
   blocking the feature. Selecting it: hide YT's player stage, show the canvas,
   `postMessage({action:"modeOn"})`, start rAF. Selecting Song/Video (or the overlay toggle off):
   reverse + `modeOff`.
4. **Preset manager**: load curated list; `loadPreset(next, blendTime)`; auto-advance timer
   (~20–30s) with blend; advance on track change (reuse the existing track-change DOM signal the app
   already observes); click / `ArrowLeft` / `ArrowRight` to skip; subtle auto-fading name toast.
5. **Fullscreen**: Fullscreen API on the container element.
6. **PiP (DEFERRED — post-v1).** Not in v1. A fast-follow gated on a dedicated spike proving
   `canvas.captureStream()` + hidden `<video>` playback + `requestPictureInPicture()` all work in
   this WKWebView on macOS 14.6 (note: `HTMLMediaElement.captureStream` is absent in WebKit, so canvas
   capture + PiP must be independently verified). v1 ships inline + fullscreen only.

## 6. Lifecycle / performance

- Tap **and** render run **only** while Visualizer mode is active. Stop the feed loop + pause rAF on:
  **track paused** (existing track observer / `trackInfo` messages), **window miniaturized**
  (`NSWindow.didMiniaturizeNotification`), **app resign-active** (`NSApplication.didResignActive`),
  and **view/window teardown**. (These are the concrete lifecycle sources — there is no generic
  occlusion API in use; enumerate them explicitly.)
- Single fullscreen WebGL2 canvas is single-digit % GPU on Apple Silicon.
- The audio bridge tolerates jitter (analysis, not playback) → worklet ring buffer + silence-on-
  underrun is sufficient; no precise jitter buffer.
- Perf risk is the **`evaluateJavaScript` call rate** (60 Hz), not bandwidth (~0.5 MB/s base64).
  If 60 Hz proves costly, drop to 30 Hz.

## 7. Error handling / edge cases

- **Permission denied** (TCC): in-canvas message ("Audio capture permission needed — enable in
  System Settings ▸ Privacy & Security ▸ Audio Capture") + a no-audio idle render (gentle motion) so
  the mode isn't broken-looking; document the re-request path.
- **macOS < 14.4 or tap API unavailable**: native `isSupported=false` → JS hides/disables the
  Visualizer segment.
- **WebGL2 unavailable**: static fallback message; no crash.
- **YT re-renders the toggle / swaps `<video>`**: MutationObserver re-injects; the feed is native so
  it's unaffected by `<video>` swaps.
- **Worklet underrun / no audio**: emit silence; visualizer idles rather than freezes.
- **Spike A finds only system-output works**: document the cross-app audio leakage as a known v1
  limitation.

## 8. Testing

- **Native**: a self-check asserting the chosen tap target produces **nonzero RMS while YT Music
  plays inside this WKWebView** (this is the real risk from §5.0 Spike A, not just buffer shape);
  assert `latestWindow` returns the requested length and goes quiet on pause.
- **JS**: assert `__milkFeed` drives a nonzero Butterchurn audio level; assert the toggle re-injects
  after a simulated container re-render and that the overlay fallback appears when the control is
  absent; assert mode on/off posts the right messages.
- **Manual**: play a track, switch to Visualizer, confirm reactivity, preset cycling, track-change
  advance, fullscreen, and that switching back to Song/Video tears down the tap.

## 9. File touch list

- **New**: `youtube-music-player/AudioTap.swift`
- **New (bundled JS resources)**: `butterchurn.min.js`, `butterchurnPresets.min.js`,
  `pcm-worklet.js`, `visualizer.js` (served via the `WKURLSchemeHandler`)
- **Edit**: `youtube-music-player/YouTubeMusicWebView.swift` (URL-scheme handler + script wiring,
  the `visualizer` message handler, the feed loop, the `isSupported` capability flag)
- **Edit**: `youtube-music-player.xcodeproj/project.pbxproj` —
  `INFOPLIST_KEY_NSAudioCaptureUsageDescription` (Debug+Release). **Note:** the project uses a
  `PBXFileSystemSynchronizedRootGroup`, so files dropped into the source folder are auto-included —
  but JS assets may be treated as compile sources rather than bundled resources. The plan must
  **verify the JS files actually land in the built `.app` bundle** (e.g. exclude from the compile
  phase / add to Copy Bundle Resources as needed) after adding them.
- **Untouched**: `ContentView.swift` / player chrome — integration lives in the webview + one native
  file (`AudioTap.swift`) + the Coordinator bridge.

## 10. Out of scope (YAGNI)

- **PiP in v1** (deferred to a spike-gated fast-follow — §5.2.6).
- Full preset browser / search / favorites (curated pack only).
- Custom/user-authored presets; per-preset config UI.
- The WebCodecs pure-webview path (revisit only if a macOS-26+ floor ever becomes acceptable).
- Capturing audio other than the app's own output (unless Spike A forces the system-output fallback).

## 11. Open risks

- **Capture target (highest risk):** out-of-process WebKit audio means the tap target is uncertain
  until Spike A. System-output fallback is the safety net (with leakage).
- **Butterchurn feed:** the exact node wiring is unproven until Spike B.
- Core Audio process-tap plumbing (aggregate device + IOProc threading + teardown) is fiddly; the
  `AudioCap` reference de-risks it.
- Matching the injected toggle segment's styling to YT's (light/dark); overlay-button fallback
  covers the worst case.
