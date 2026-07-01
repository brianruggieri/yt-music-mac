# Phase-0 Spike Results (Tasks 1–2) — both PASS

Runtime-verified in the Release build, WKWebView, YT Music playing real tracks.

## Spike A — Core Audio process tap target (Task 1)

Per-target RMS, two passes (PLAYING vs PAUSED):

| Target                | PLAYING   | PAUSED   | Notes                                   |
|-----------------------|-----------|----------|-----------------------------------------|
| host app PID          | 0.000000  | 0.000000 | webview audio is NOT on the main process |
| WebKit child (other)  | ERROR/0   | ERROR/0  | stale system-wide WebKit helpers (other apps) |
| **WebKit GPU child**  | **0.0858**| **0.000**| ✅ carries the music; PID adjacent to host |
| systemOutput (global) | 0.0881    | 0.000    | ✅ tracks too, but whole-system          |

**Conclusion:** the audio-producing process is the app's **WebKit GPU child**
(the child PID adjacent to the host PID, with a valid Core Audio process object).
It is app-isolated and follows play/pause exactly. `systemOutput` is an
always-works fallback but captures every app's audio.

**TAP_TARGET decision (chosen): app-isolated WebKit child.** The visualizer must
react only to YT Music, not all system audio. The PID is NOT stable across
launches, so Task 3 discovers it at runtime:

1. Enumerate WebKit GPU/WebContent child PIDs (`ps`, as the spike does).
2. Keep only those whose **responsible process == our app PID** — via
   `responsibility_get_pid_responsible_for_pid(pid)` (private but stable; what
   AudioCap-style code uses). This survives WebKit's launchd re-parenting and
   excludes OTHER apps' WebKit helpers (the 4557/4573 leak seen in the spike).
3. Translate each survivor with `kAudioHardwarePropertyTranslatePIDToProcessObject`;
   skip PIDs with no audio object.
4. Tap the survivors as `CATapDescription(stereoMixdownOfProcesses:)`. Silent
   children (WebContent) mix down harmlessly; the GPU child carries the music.
5. Rebuild the tap on visualizer re-activation (WebContent can be replaced on
   reload/crash). ponytail: rebuild-on-activate now; add live crash-recovery only
   if it proves flaky in real use.

Do NOT blindly mixdown the raw `webKitChildPIDs` list — it includes other apps'
helpers. The responsible-PID filter is the load-bearing step.

## Spike B — Butterchurn feed recipe (Task 2)

- `ctx.audioWorklet.addModule(blob:)` **succeeds** under YT Music's CSP —
  blob: worklets are NOT blocked. Task 5 needs no worklet CSP fallback.
- Butterchurn global is the webpack module namespace; real API at
  `window.butterchurn.default` / `window.butterchurnPresets.default`
  (resolve `.default || global`). See VERSIONS.txt.
- Proven node graph: AudioWorkletNode(2ch) → viz.connectAudio(node) +
  GainNode(0)→destination (keeps the graph pulled) + AnalyserNode (level).
- Result: `FEED OK`, RMS ~0.35, canvas renders live presets.
