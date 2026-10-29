# MSE Audio Bridge Feasibility — Song/Video Mode Toggle Gap

**Verdict: FEASIBLE.** Core MSE mechanics (capture via `appendBuffer` hook, replay via a second hidden media element + `timestampOffset`) are exactly what Chrome's own media team demonstrates works for gapless audio. The single biggest blocker is not technical: it's **fragility** — the hook depends on undocumented, unstable YouTube player internals (exact codec/container, call sequence, and the possibility YT moves off MSE onto WebCodecs) that can silently break with a YT deploy, with no upstream API contract to lean on.

## 1. Prior art

No widely-documented userscript specifically titled "intercept SourceBuffer.appendBuffer for gapless bridging" turned up. Two useful anchors instead:

- **Google/Chrome's own reference implementation is the closest prior art and it validates the mechanism directly**: ["Media Source Extensions for Audio: Eliminating the Gap"](https://developer.chrome.com/blog/media-source-extensions-for-audio) (demo: dalecurtis.github.io/llama-demo) uses two `SourceBuffer`s and `timestampOffset` to splice a second audio source into a running MSE timeline with no audible seam. That is structurally the same operation this bridge needs (append captured segments at a controlled offset), just applied to a captured/retained buffer instead of a "next track."
- YouTube-downloader browser extensions establish that hooking `appendBuffer`/`fetch` at the page-JS level to capture YouTube media bytes is a well-trodden pattern in general (ad-blockers, stream rippers), though most of those intercept at the network layer, not the `appendBuffer` layer — which turns out to matter (see §5).

No evidence found of anyone doing exactly this "bridge audio through a mode-switch gap" trick — it appears to be a novel application of known building blocks, not a re-implementation of an existing tool.

## 2. Container/codec YT Music serves

- Audio-only itag 251: **Opus in WebM**, ~128kbps (also lower-bitrate 250/249, and a newer itag 600 family). This is the common default in modern Chrome.
- Audio-only itag 140: **AAC in fragmented MP4 (m4a)**, ~129kbps, served as fallback for clients/situations that don't get Opus.

Both are segment-based container formats designed for MSE: a WebM stream has an init segment (EBML header + `Tracks` element, before the first `Cluster`) followed by `Cluster` media segments; fMP4 has an init segment (`ftyp`+`moov`) followed by `moof`+`mdat` media segments. **Both replay cleanly in a second, independent `MediaSource` instance** as long as you retain the init segment plus the trailing media segment(s) — this is exactly the pattern `SourceBuffer.timestampOffset` exists for (per MDN/W3C spec: it "controls the offset applied to timestamps inside subsequent media segments," used precisely for this kind of splice/reposition use case).

Practical note: whether Song mode and Video mode serve the *same* audio itag or different ones doesn't matter for the bridge — the bridge plays retained old-stream segments through its **own** `MediaSource`/`<audio>` element with a `SourceBuffer` opened against the *old* stream's mimeType/codecs string. It never needs to be compatible with the new stream's codec.

## 3. `decodeAudioData` on fragmented segments

Confirmed **not viable**: `decodeAudioData` needs a complete, self-contained encoded audio file (or at minimum a fragment that already carries full container/codec setup); it does not reliably decode a bare fMP4/WebM media segment lacking the moov/init data, and is not the right tool for streaming fragments in general. **Skip Web Audio entirely for the bridge.** The minimal viable path is a second same-context `<audio>` element with its own `MediaSource` — no `AudioContext`, no `decodeAudioData`, no `createMediaElementSource` needed (which also sidesteps the CORS-taint problem entirely, since the bridge only needs to *play* audio, never *read* its samples).

## 4. Timing precision / crossfade feasibility

Starting a second `<audio>` element and calling `.play()` is fast (sub-frame in practice) and `currentTime` seeking is directly settable — aligning it to "wherever the main track was when it went silent" is straightforward, no different from what any gapless-playback MSE implementation (Chrome's own demo, Shaka Player-based radio players) already does with `timestampOffset` + multiple `SourceBuffer`s. A plain `<audio>.volume` ramp (no Web Audio graph required) is sufficient for a ~150–250ms fade; a `GainNode` would only be needed for more exotic curves. The ~250-450ms silence window measured is comfortably coverable by ~1-2 retained media segments (segments are typically ~1-4s each at this bitrate, so even one retained segment holds several times the gap duration — the constraint is having *any* segment ending at/after the toggle point, not running out of audio).

## 5. Risks

- **SABR/UMP — turns out to be a non-issue for this specific approach, and actually an argument *for* hooking at `appendBuffer` rather than at `fetch`/network.** YouTube's `web` client (which covers `music.youtube.com`) has been migrating to SABR, a proprietary transport where the network response is UMP-framed protobuf (`MEDIA_HEADER`/`MEDIA`/`MEDIA_END` parts), not a plain segment URL. **But this is purely a wire-transport format.** The browser's native MSE implementation can only accept the container format declared in the `SourceBuffer`'s `mimeType`/`codecs` (ISO-BMFF or WebM) — it cannot decode raw UMP/protobuf. YouTube's own page JS must therefore unwrap the UMP framing and call `appendBuffer()` with standard, spec-valid init/media segments regardless of SABR (confirmed via inspection of `LuanRT/yt-sabr-shaka-demo`, which does exactly this: parses UMP, reconstructs standard ISO-BMFF for the player). **A hook on `SourceBuffer.prototype.appendBuffer` sits downstream of all of that and sees clean segments no matter what the wire format was** — this would *not* be true of a `fetch`/`XHR` interception approach, which would need to parse UMP itself. This is the strongest argument for the `appendBuffer`-hook architecture specifically.
- **Real biggest blocker: hook fragility.** The whole scheme depends on reverse-engineered, undocumented behavior — exact codec/container choice, when/how many `SourceBuffer`s YT creates, and whether YT's web player continues to use MSE at all (some players have experimented with WebCodecs + `AudioWorklet` for finer-grained control, which would bypass `SourceBuffer` entirely and silently break this hook with zero warning, not even an error). This needs to fail gracefully (bridge just does nothing, falling back to today's ~250-450ms silence) and needs a maintenance owner.
- **Memory**: trivial. A few seconds of retained Opus/AAC audio at ~128kbps is tens of KB.
- **New `MediaSource` per mode switch**: confirmed by spec — the `emptied` event fires specifically when the element transitions to `NETWORK_EMPTY` (src reassigned / `load()` called), which is consistent with YT tearing down and creating a fresh `MediaSource` for the new stream on toggle. This doesn't threaten the plan: the capture hook is a `prototype`-level patch (survives across `MediaSource`/`SourceBuffer` instances) and the retained buffer lives in a separate, persistent JS object, not tied to the old `MediaSource`'s lifecycle.

## Minimal viable architecture

1. **Inject before player boot.** Monkey-patch `SourceBuffer.prototype.appendBuffer` once. On each call, copy (slice) the appended bytes into a small ring buffer keyed to that `SourceBuffer`'s `mimeType`; identify and separately retain the init segment (first append after a fresh `SourceBuffer`, or detect via WebM EBML magic `0x1A45DFA3` / fMP4 `ftyp` box) plus the last 1-2 media segments, evicting older ones by byte-size cap (a few hundred KB is generous headroom).
2. **On mode-toggle detection** (the `emptied` event on the primary media element, or an earlier internal signal if one can be found for tighter timing): create a hidden `<audio>` + `new MediaSource()`, `URL.createObjectURL` it in, and on `sourceopen` add a `SourceBuffer` with the *retained* mimeType/codecs. Append the retained init segment + trailing media segment(s), set `timestampOffset` so the segment's original timestamp lands at "now," seek `currentTime` to the main track's last known position, and `.play()`.
3. **Cross-fade**: ramp the bridge `<audio>.volume` from 1→0 over ~150-250ms once the primary element's real new stream starts producing audio (`playing` event, or a fixed timer matched to the measured gap), then tear the bridge element down.

No `AudioContext`, no `decodeAudioData`, no `GainNode` required for the minimum version — plain `<audio>.volume` fades cover it.
