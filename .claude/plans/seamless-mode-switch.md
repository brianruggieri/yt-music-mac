# Seamless Song↔Video Mode Switch — Spec v5 (final)

Status: FINAL after four codex adversarial review rounds (20+11+10+6 findings; all addressed).
Remaining risk lives in code — the implementation diff gets its own cross-model review (task 7).
Research inputs: `.claude/research-audio-bridge.md`, `.claude/research-loudness-match.md`
Measured baseline: toggle = full media teardown (`emptied`) + other-stream load + seek; ~250–450ms
audio silence, identical in plain Chrome. Visual side already masked by the snapshot
cross-dissolve in `visualizer.js` (`swapFade`).

## Goal

1. **Audio bridge** — keep the outgoing stream's own audio playing across the ~300ms gap,
   ramped out as the incoming stream starts.
2. **Loudness match** — eliminate the volume jump between the two independently-mastered
   uploads (ATV vs OMV are separate videoIds), anchored to the outgoing stream.

Both **fail-silent** (any error degrades to today's masked gap, never broken playback), both
independently kill-switchable (`window.__smootherFlags = {bridge:true, loudness:true}` const at
top of file), shipped as separate commits.

## Architecture

### New file: `youtube-music-player/Resources/visualizer/stream-smoother.js`

Injected at **`.atDocumentStart`**, main frame only, BEFORE all other scripts (fetch hook must
see the first `/player` call; prototype patches must precede player boot). Self-gates on
`location.hostname` (music.youtube.com). Every hook follows the **call-original-exactly-once**
pattern (codex #11): our bookkeeping runs in its own try/catch; the original is invoked once,
outside any retry path, and its return/throw passes through untouched.

Files touched: `stream-smoother.js` (new), `YouTubeMusicWebView.swift` (inject script; extend
probe). `visualizer.js` unchanged — the smoother's position tracker supersedes event `ct`.

### Hook layer (foundation)

1. **`fetch` wrapper** — on `/youtubei/v1/player` responses: async `clone().json()`, cache
   `videoId → {loudnessDb, perceptualLoudnessDb, ts}` (Map, cap 20, LRU). Cache is looked up
   **by videoId only** — never "most recent response" (codex #10). Active videoId comes from
   `location.search` `v=` param read at the moments of interest. Cold-load track covered by a
   one-time DOM-ready read of `ytInitialPlayerResponse`.
2. **`URL.createObjectURL` wrapper** — when passed a `MediaSource`, record `url → MediaSource`
   (WeakRef-friendly small map). This is how the smoother knows which MediaSource is actually
   attached to the main `<video>` (`video.src` lookup), fixing ownership (codex #4): preload or
   ad MediaSources are ignored.
3. **`MediaSource.prototype.addSourceBuffer` + `changeType` wrappers** — tag each SourceBuffer
   with its current mime; `changeType` resets that buffer's retention (codex #16).
4. **`SourceBuffer.prototype.appendBuffer` wrapper** — for `audio/*` buffers: normalize
   `ArrayBuffer|ArrayBufferView` and copy bytes. **No segment classification** (codex #2 —
   appends are arbitrary chunks): retain the buffer's **ordered append history**. Each copy is
   held as **pending until that append's `updateend`** fires, then committed — pending state
   becomes visible only after the native call returns without throwing, and pending-drop /
   retention-reset happen only after the corresponding native `abort()`/`changeType()` succeeds
   (codex r3 #5). A **successful `abort()` additionally marks the buffer's retention
   non-replayable** (codex r3 #3 — abort resets MSE parser state mid-segment; a concatenated
   replay would feed the next epoch bytes the parser discarded; conservative decline is correct
   and seek-adjacent bridging was already an accepted limitation). `changeType`/fresh
   SourceBuffer clears the mark.
   Per-append `timestampOffset`/`appendWindowStart|End`/`mode` are recorded; any non-default
   value marks the retention non-replayable and the bridge will abort rather than misalign
   (codex r2 #9). Byte cap **8MB total live budget across all retained buffers** (evict whole
   non-attached MediaSource groups first) with *stop-retaining* semantics — never evict the
   head, never partially retain a cap-crossing chunk, emit `retention-cap` telemetry
   (codex r2 #8). `changeType` resets the buffer's retention. **Owned MediaSources/SourceBuffers
   (the bridge's own) are WeakSet-marked at creation and excluded from capture and budget
   accounting entirely** (codex r3 #6 — otherwise the bridge's replay re-enters the hook,
   duplicating retention and polluting the cap).
5. **`HTMLMediaElement volume` accessor patch — installed only by the loudness module**
   (codex r2 #7): setter validates the public value first (out-of-range delegates straight to
   the native setter so native errors reproduce exactly), then writes `userVolume × compGain`
   natively, committing stored `userVolume` only after the native write succeeds (codex r2 #10);
   getter returns `userVolume`. Compensation becomes an invisible gain layer — YT's slider UI,
   persistence, and `volumechange` round-trips observe their own value: no feedback loop, no UI
   jump, no persisted attenuation, no base/compensation entanglement. **Scope: elements the
   smoother owns (bridge audio, marked) always pass through natively — compGain applies only to
   non-owned elements** (codex r2 #2; ads/preloads share the layer, acceptable since comp
   resets on videoId change). `compGain` changes re-apply from stored `userVolume` — never
   read-modify-write. Probe asserts getter stability across a compensation change.
6. **Playback-position tracker** — capture-phase `timeupdate`/`playing`/`waiting`/`pause`/
   `seeking`/`ratechange` listeners on `document` (capture reaches media elements without
   bubbling and survives element replacement — codex #5): keep `{lastCt, wallTs, rate,
   advancing}` for the main video. Estimated position (seconds) =
   `lastCt + (advancing ? (nowMs − wallTs)/1000 × rate : 0)` (codex r2 #5) — never click-time
   `ct` alone.
7. Telemetry: `ytm-smoother` CustomEvents (module, event, detail) — consumed by the probe.
   Flags: `window.__smootherFlags` is seeded-if-absent (`ponytail:` pre-seeded values win —
   codex r2 #7).

### Module: audio bridge

Trigger: `ytm-swapfade` `{phase:'out'}`. Each trigger takes a **generation token**; a new
`out` immediately tears down any prior bridge (codex #13).

1. Guards (all abort silently w/ telemetry reason): flags.bridge on; retained audio exists,
   replayable, for the MediaSource currently attached to the main video (via wrapper 2; if that
   MediaSource has multiple audio SourceBuffers, use the most-recently-appended whose replay
   covers the tracked position — codex r2 #9); main video not muted, effective volume > 0, not
   paused, `playbackRate === 1` (non-1× → abort, simpler than mirroring drift — codex r2 #5);
   position tracker reports `advancing === true` (a stalled/waiting element has
   `paused === false` but no audio to continue — decline, codex r4 #6);
   player not in ad state (`.ad-showing` / `ytmusic-player[ad-showing]`).
2. Build: hidden owned `<audio>` + own MediaSource; on `sourceopen`, `addSourceBuffer(mime)`.
   **Start is a two-input latch** (codex r4 #1): `replayReady && emptiedSeen && !handoverSeen` —
   the bridge never emits audio while the outgoing element is still alive (no
   doubling/flanging); mark play-requested before invoking `play()` so a handover during the
   pending promise still tears it down.
   **Concatenate the committed history into ≤3 large appends** (byte-identical stream; kills
   the per-chunk `updateend` round-trip startup cost — codex r2 #3), still serialized through
   `updateend` (codex #1; `QuotaExceededError` → abort). Default timestampOffset (original
   timeline). After final `updateend`: if tracked position ∉ `buffered` → abort. Telemetry logs
   `out → bridge playing` latency.
3. Start: `bridge.currentTime = trackedPos`; `preservesPitch` mirrored;
   bridge volume = read the MAIN element via the saved native getter, write the BRIDGE via the
   saved native setter (post-compensation value, so any YT loudness DSP expressed through
   element volume is inherited — codex #12, r3 #10);
   `play()` — promise rejection → abort (codex #17).
4. Live guards during bridge life — **phase-aware** (codex r2 #1): the swap itself fires
   `pause`/`emptied`/`seeking` on the main element, so those are NOT teardown signals. Teardown
   triggers: main `volumechange` where `muted === true` or native effective volume 0; main
   `ratechange` away from 1; `pagehide`; bridge element `error`, bridge SourceBuffer `error`,
   MediaSource `sourceclose`. **The bridge volume is fixed at capture and never mirrors later
   `volumechange`** (codex r3 #1 — compensation-induced re-applies queue `volumechange`
   asynchronously and are indistinguishable from user input at event time; mute/zero detection
   reads element state, not the event, so it stays). A user slider move during the ≤2s bridge
   life is accepted as unmirrored. A mid-swap user pause is bounded by the 2s backstop
   (accepted, rare race).
5. End: qualified handover (codex #5) — teardown-with-ramp only when, **after** the swap's
   `emptied` has been observed, a `playing` fires on the main video AND its `currentTime > 0`.
   Ramp `bridge` native volume → 0 over ~150ms, then teardown (pause, revokeObjectURL, remove).
   Overlap during ramp is the intended audio crossfade.
6. Hard teardown at 2000ms regardless (codex #17 note: timer is backstop, not primary).
7. **Handover latch** (codex r3 #2): the qualified-handover observer arms at `out`, before the
   async build begins. Every async continuation (`sourceopen`, each `updateend`, the `play()`
   promise) generation-checks AND checks `handoverSeen` — once handover has occurred the bridge
   never starts; if already started, it ramps immediately. Stale-start overlap is impossible.

`ponytail:` bridge covers toggle-initiated swaps only; if YT moves off MSE, retention never
populates and everything no-ops.

### Module: loudness match

1. State: `comp = {gain:1, videoId:null}` feeding the volume patch's `compGain`. Explicit —
   user volume and compensation never share a storage slot (codex #7).
2. On `ytm-swapfade out`: `oldId = v= from URL`, snapshot `L_old`.
3. **Gain is staged during the swap and applied at the pre-audio boundary** (codex r3 #4,
   r4 #2): `playing` is queued AFTER audio may already be audible, so it is not the apply
   point. Staging: when a `/player` response arrives during an open swap window with
   `videoId ≠ oldId`, stage `{generation, newId, gain}` — generation-bound, and revalidated at
   apply time against the incoming stream's actual videoId (codex r4 #5). Application: at the
   swap's `emptied` (resource teardown — guaranteed pre-audio), reset old compensation AND
   apply the staged gain if present; staging arriving in the emptied→playing window applies on
   arrival; nothing staged by `playing` → stays reset, skip. No post-audible step ever.
   **Normalization model** (codex #6 — avoid double-correction): YT's own pipeline is
   attenuate-only toward its reference, so the *post-normalization* loudness of a stream is
   `min(L, 0)`. `deltaDb = min(L_new,0) − min(L_old,0)`.
   - `deltaDb > +0.5`: `comp.gain = 10^(−deltaDb/20)` (attenuate incoming).
   - `deltaDb < −0.5`: incoming quieter — no boost path exists; `comp.gain = 1`. Documented
     residual dip.
   - else: `comp.gain = 1`.
4. **Every terminal path resets** (codex r2 #6): apply, skip-missing-metadata, handover
   timeout (3s), cancellation, track change — each ends with either the freshly computed gain
   or `comp = {gain:1}`. Track-change reset (codex r3 #7, hardened r4 #4): **unconditional** —
   every `emptied`/`loadstart` on the main video OUTSIDE a swap window resets compensation
   before playback of whatever comes next (no URL correlation to get wrong; a swap re-applies
   its own staged gain, so normalized-track behavior is unaffected). Compensation can never
   leak across streams.
5. **Flag semantics** (codex r3 #8): one-way lazy install — the accessor installs on the first
   swap that runs with `flags.loudness` truthy; `flags.loudness = false` at runtime keeps the
   accessor but forces `compGain = 1` immediately (transparent pass-through). The probe's A/B
   uses exactly this path (starts all-off, enables mid-session). **Install migration**
   (codex r4 #3): at install, seed each existing unowned media element's `userVolume` from the
   saved native getter before the descriptor is replaced; elements first seen later seed
   lazily on first accessor touch. Readback can never jump or return undefined.
5. **Merge gate**: probe run logs `{L_old, L_new, deltaDb, gain}` for a real ATV/OMV pair +
   AudioTap RMS trace (below) confirms the level step shrinks, not grows. Both the sign
   convention AND the min() model are runtime-verified before merge; if the RMS step worsens,
   ship bridge only and hold loudness behind its flag (codex #19 honored: independent flags,
   separate commits, loudness can be reverted alone).

### Interaction

Bridge plays OLD stream at the main element's pre-swap effective volume (inherently matched);
compensation retargets the NEW stream to the old level at handover; bridge ramps into it.
Bridge volume is captured once and frozen; compGain applies only to non-owned elements — the
one cross-coupling (comp-induced `volumechange` reaching bridge mirroring) is removed by not
mirroring at all.

## Implementation plan

| # | Task | Owner |
|---|------|-------|
| 1 | Foundation: branch, commit existing cross-dissolve + probe; `stream-smoother.js` with full hook layer + telemetry + empty module slots; Swift injection; `ct` in `ytm-swapfade` | lead |
| 2 | Loudness module | implementer subagent A → reviewer subagent |
| 3 | Bridge module (serialized after 2 — same file) | implementer subagent B → reviewer subagent |
| 4 | Probe extension (smoother telemetry + AudioTap RMS trace) + in-app verification; harness | lead |
| 5 | Codex diff review → fixes → push → PR | lead |

## Test plan

- **Probe run** (Debug, `YTM_TOGGLE_PROBE=1`), assertions from captured log:
  - loudness cache entries for both videoIds; `apply`/`skip` with gain ≤ 1; formula inputs logged.
  - bridge `start` → `end` (no `abort`) both toggle directions; generation token respected on a
    rapid double-toggle case.
  - media-event shape unchanged; FADE events still bracket.
  - **Audio-level ground truth** (codex #18, hardened per r2 #11): probe activates the native
    AudioTap feed and logs per-frame RMS around each toggle. **A/B within one session**: first
    toggle pair runs with `__smootherFlags` all-off (control), then flags-on pairs. Every
    control and treatment toggle pair is **position-matched**: seek to the same timestamp and
    await `seeked` + settle before each pair (codex r3 #9); the rapid double-toggle case is
    evaluated separately, not against the step budget. Measurement
    windows exclude the 150ms ramp overlap; silence threshold calibrated from the control run's
    gap floor. Pass: flags-on silent window < 120ms (control ~300ms); handover RMS step
    (500ms pre/post, overlap excluded) ≤ control's step. Waveform-level, not event sequencing.
- **Harness**: full suite; pass bar = no NEW failures beyond the 3 pre-existing drift failures
  (verified pre-existing on clean main 2026-08-08).
- **Fail-silent review checklist**: hooks call original exactly once; bridge teardown idempotent
  + generation-guarded; smoother inert on non-music hosts, empty retention, missing metadata;
  volume patch transparent to YT (getter returns userVolume always).

## Accepted limitations (documented, not bugs)

- Incoming-quieter direction: unfixable dip (no boost path on tainted element).
- Cold-load first toggle may skip compensation until `ytInitialPlayerResponse` read lands.
- Bridge aborts (by design) right after a user seek, when retention doesn't cover position.
- Rapid toggles: previous bridge is torn down instantly (no ramp) — brief hard cut, safe.
- Retention cap: toggles later than ~8MB of appended audio (~8min at 128kbps) stop bridging
  for that track (`retention-cap` telemetry marks it); masked-gap behavior remains.
- Mid-swap user pause: bridge may sound up to the 2s backstop (rare race, bounded).
- Non-1× playbackRate: bridge declines (abort), loudness unaffected.
