# Research: Loudness-matching Song ↔ Video switches (YT Music web)

Goal: when the user toggles Song/Video mode on a playing track, compensate for the
loudness/mastering difference between the audio-only stream (ATV) and the music-video
stream (OMV) so the switch doesn't produce an audible volume jump — anchored to
whichever source is currently playing, using only `video.volume` (CORS-tainted media
element, no Web Audio gain path).

Confidence is marked per claim: **confirmed** (directly sourced), **likely** (strong
indirect evidence / well-established community knowledge), **unconfirmed** (single weak
source, needs runtime verification before relying on it).

---

## 1. The loudness metadata fields

**Confirmed** (via a real TypeScript type addition to `node-ytdl-core`,
[commit 273cf1a](https://github.com/fent/node-ytdl-core/commit/273cf1a807f5666f1e222b2c8aa5e4c22def1b93)),
`ytInitialPlayerResponse.playerConfig.audioConfig` has this shape:

```ts
audioConfig: {
  loudnessDb: number;
  perceptualLoudnessDb: number;
  enablePerFormatLoudness: boolean;
}
```

- **`loudnessDb`** — the dB offset YouTube's own normalization pipeline has computed
  for this video relative to YouTube's fixed platform-wide loudness reference. This is
  the same underlying mechanism documented publicly for "Stats for Nerds" → **Content
  Loudness** (see below): a **positive** value means the source is *louder* than the
  reference and that many dB of *attenuation* is applied; a **negative** value means the
  source is *quieter* than reference and **no gain is added** — YouTube never boosts
  ([productionadvice.co.uk](https://productionadvice.co.uk/stats-for-nerds/),
  [AudioLab loudness standards writeup](https://audio.rswaver.com/blog/youtube-loudness-standards)).
  The commonly cited platform reference is **‑14 LUFS integrated / ‑1 dBTP true peak**
  (widely corroborated across mastering-for-YouTube guides — this is the number YouTube
  documents for its own normalization target).
- **`perceptualLoudnessDb`** — a perceptually-weighted variant of the same measurement
  (K-weighted/BS.1770-style loudness vs a more perception-tuned model). In practice the
  two values track closely; treat `perceptualLoudnessDb` as the more accurate one to
  prefer when both are present. **Likely**, not confirmed by a spec doc.
- **`enablePerFormatLoudness`** — signals that loudness should be looked up **per
  adaptive format**, not just once for the whole video. **Likely**: individual entries
  in `streamingData.adaptiveFormats[]` can each carry their own `loudnessDb` /
  `averageLoudness`-style fields (different encodes of the same source audio are
  usually identical in loudness, but this flag exists because they aren't guaranteed to
  be — e.g. if a format was transcoded from a different master). No authoritative schema
  doc was found; this is community/type-inference knowledge, not a spec.
- These fields are **per-video** (the top-level `audioConfig.loudnessDb`), with an
  optional **per-format** override when `enablePerFormatLoudness` is true. They are *not*
  a track-level concept spanning multiple uploads — each `videoId` gets its own value
  computed independently.

No official Google/YouTube documentation for this schema was found (it's not part of the
public Data API); everything above comes from reverse-engineering by yt-dlp/ytdl-core
maintainers and downstream analysis blogs. Treat field *names* as solid (widely
consistent across independent reverse-engineering efforts) but the exact sign convention
as **needs a runtime log-and-verify pass**: dump `loudnessDb` / `perceptualLoudnessDb`
for a real ATV/OMV pair of the same song and confirm sign and magnitude before shipping
gain math against it.

## 2. Does YT Music already normalize both streams to the same target?

Two separate systems are in play, and this is likely the actual source of the residual
jump:

- **YouTube's platform-wide loudness normalization** (`loudnessDb`-driven, applies to
  the general www.youtube.com player) targets ‑14 LUFS and is attenuate-only.
- **"Stable Volume"** is a *separate*, playback-time smoothing feature. One low-confidence
  source (a Head-Fi thread + a MiniTool explainer, **unconfirmed**, single weak source)
  claims Stable Volume is **turned off for YouTube Music and official music videos**
  specifically — i.e., the feature most people know as "YouTube's auto-volume-leveling"
  may not be the thing acting on either the ATV or the OMV stream inside
  music.youtube.com at all.
- YouTube Music also ships its own **"Loudness Normalization" / "Consistent Volume"**
  toggle under Settings → Playback → Equalizer
  ([HowToGeek](https://www.howtogeek.com/i-changed-this-hidden-setting-and-instantly-improved-youtube-music-audio-quality/)),
  which is a *distinct* subsystem again, and its interaction with `loudnessDb` metadata
  is undocumented.

**Working theory** (moderate confidence, matches the reported symptom): the ATV (song)
and OMV (video) are two completely independent uploads with independently mastered/mixed
audio and independently computed `loudnessDb`. Even if YouTube's per-video normalization
is active on both, it is **attenuate-only toward a shared ‑14 LUFS ceiling** — so if both
tracks sit *below* that ceiling (very common for masters that aren't hot), neither gets
touched, and the raw mastering difference between the song mix and the video mix passes
straight through, uncorrected. That gap is exactly what's audible at the toggle. This is
consistent with the field semantics in §1 and doesn't require Stable Volume to be
involved at all — it explains the jump even if every normalization system YouTube runs
is working exactly as designed.

## 3. Song vs Video are different `videoId`s with independently mastered audio

**Confirmed** via ytmusicapi terminology and YouTube Music's own feature announcement:

- **ATV** ("Audio Track Version") — a YouTube Music–specific upload: static cover art +
  the song's audio track, uploaded by/for the artist.
- **OMV** ("Official Music Video") — the real music video, a normal YouTube upload.
- These are **two separate `videoId`s**, each with its own full Innertube player
  response, its own `streamingData.adaptiveFormats`, and its own
  `audioConfig.loudnessDb` — not variants of a single upload. YouTube Music's
  song/video toggle (announced on the [YouTube Blog](https://blog.youtube/news-and-events/youtube-music-now-lets-listeners-switch/))
  swaps the player to the other `videoId` and (per that announcement) does its own
  time-alignment between the two, but nothing in that announcement claims loudness
  matching is part of the feature.
- Because they're independent uploads, it's entirely plausible (and consistent with §2)
  that the OMV's audio is a different mix/master than the ATV's (video mixes are often
  louder/more dynamic-range-compressed for cinema-style playback), which is the direct
  mechanical cause of the jump.

## 4. How third-party clients/extensions handle this

- **yt-dlp / node-ytdl-core**: expose `loudnessDb` as raw metadata (confirmed field
  presence, per §1) but neither tool was found to *apply* it — both are downloaders, not
  players, so there's no first-party reference implementation of the gain math to crib
  from. GitHub/web search did not turn up an authoritative "here's exactly how to turn
  loudnessDb into a volume multiplier" doc from Google or yt-dlp maintainers.
- **`youtube-volume-normalizer`** (Kelvin-Ng, Chrome/Firefox extension,
  [source](https://github.com/Kelvin-Ng/youtube-volume-normalizer)) is the most concrete
  prior art found:
  - **Data source**: it does *not* read the player-response JSON. It scrapes YouTube's
    **Stats for Nerds** panel (simulated clicks) to read the displayed "Content Loudness"
    dB value — i.e. it treats the UI-rendered figure as ground truth rather than hooking
    network responses.
  - **Gain formula (confirmed, quoted from its README)**: for a content loudness of
    `‑8.0 dB`, gain = `10^(8/20) × 100% = 251%`. I.e. **`gainLinear = 10^(|dB| / 20)`** —
    the standard dB-to-linear-amplitude conversion, confirming the sign/magnitude
    intuition in §1 (negative content-loudness ⇒ needs boosting).
  - **No-boost workaround (this is the key transferable insight)**: since amplifying
    past 1.0 isn't possible through the media element's `.volume`, this extension routes
    audio through the **Web Audio API** and applies a `GainNode` for values > 1.0, backed
    by a `DynamicsCompressorNode` as a limiter to avoid clipping when boosting. This
    is exactly the class of workaround **not available to this app**, since the app's
    media element is CORS-tainted (`createMediaElementSource` → silence per your prior
    finding, see `[[visualizer-audio-tap-tainted]]`-style constraint) — no Web Audio graph
    can be built on top of the video element here.
- No other extension/userscript with a public, inspectable gain algorithm was found in
  this pass (several "volume booster" extensions exist on the Chrome Web Store but their
  source isn't public, so their formulas can't be verified — treat any specific claims
  about them as unconfirmed).

## 5. Injection strategy to obtain the new stream's loudness at switch time

Two viable approaches, in order of robustness:

1. **Hook `window.fetch` (and `XMLHttpRequest.open`/`.send` as a fallback) for POST
   requests matching `/youtubei/v1/player`**, parse the JSON response body, and cache
   `playerConfig.audioConfig.{loudnessDb,perceptualLoudnessDb}` keyed by the `videoId`
   in the request payload, *before* letting the response continue to the app's own
   handler. This is a well-established pattern — confirmed present in real-world
   YouTube userscripts (e.g. the
   [lbmaian "YouTube - Playback Fixes" gist](https://gist.github.com/lbmaian/5b1ff91593c9c0dc9262bfa74e8a5ad9),
   which intercepts exactly this endpoint via a proxied `fetch`, and ad-blocker/bypass
   userscripts that intercept the same endpoint for `playabilityStatus` rewriting). This
   is the injection point to use: it fires once per navigation (including the
   Song↔Video toggle, since that swaps `videoId` and triggers a fresh `/player` call),
   is available *before* the new stream starts audibly playing (response arrives ahead
   of playback start), and doesn't depend on any internal Polymer/player object shape
   that could change between YT Music releases.
2. **Fallback / cross-check**: `ytmusic-player` (or the underlying `<ytmusic-app>`
   Polymer element) typically exposes a `getPlayerResponse()`-style method on the player
   custom element once a video is loaded, letting you re-read the already-parsed
   response without re-parsing JSON. This is lower-effort but more fragile (relies on
   YT Music's internal element API staying stable) — use only as a belt-and-suspenders
   read if the fetch hook ever misses a request (e.g. due to caching/prefetch paths),
   not as the primary source.

Either way: read `loudnessDb` (prefer `perceptualLoudnessDb` if present and non-null) for
the **new** `videoId` being switched to, and you already have (or can cache) the same
value for the **currently playing** `videoId` from when it was first loaded.

## 6. The gain formula, and the no-boost constraint

Standard dB→linear conversion (confirmed via the extension's README, §4):

```
gainLinear = 10 ^ (deltaDb / 20)
```

Where `deltaDb` is defined **relative to the currently-playing stream**, not to an
absolute target — because the goal is continuity at the switch point, not hitting a
fixed reference:

```
deltaDb = loudnessDb(new) - loudnessDb(old)     // sign convention needs runtime verification, see §1
```

Given the established sign convention (positive `loudnessDb` = louder than reference,
already-attenuated by that much by YouTube's own system; negative = quieter, unattenuated):
if the *new* stream's `loudnessDb` is **higher** (more positive / less negative) than the
old stream's, the new stream is louder — you need to **attenuate the new stream** to
match. If the new stream's `loudnessDb` is **lower**, the new stream is quieter, and you
would need to *boost* it to match — which `video.volume` (max 1.0) cannot do.

**No-boost constraint, resolved (this is the actual verdict):** since only attenuation is
possible, and the anchor is explicitly "whichever source is currently playing" (per your
framing, not a fixed absolute target), the correct behavior is:

- If the incoming stream is **louder** than the outgoing one: attenuate the incoming
  stream's `video.volume` by `gainLinear = 10^(-|deltaDb|/20)` (multiplied on top of the
  user's own volume slider setting, exactly as the existing normalizer extensions do —
  multiplicative, not a replacement of the user's chosen level) so it lands at the same
  perceived loudness as what was just playing.
- If the incoming stream is **quieter**: **do nothing** — leave `video.volume` at the
  user's slider value. You cannot boost a `<video>` element past 1.0, and there is no
  Web Audio path available here (CORS-tainted), so a perceived dip on switch-to-quieter
  is the unavoidable residual case. This is the same limitation every attenuate-only
  normalizer has; the difference from a full solution (like the Web Audio
  gain-node-plus-compressor trick in §4) is exactly the missing boost headroom, and that
  trick is not portable to this app's tainted media element.
- **Anchor to "currently playing," not to a fixed target**: don't normalize both streams
  independently against ‑14 LUFS (that reintroduces the "both under threshold, no
  correction happens" problem from §2). Compute `deltaDb` directly between the two
  `loudnessDb` values at switch time and apply attenuation only in the direction that
  needed it — this makes the switch itself continuous regardless of where either stream
  sits relative to YouTube's platform reference.
- Reset the compensation multiplier when a *new track* starts playing normally (not via
  toggle) — treat every switch as a fresh currently-playing anchor so compensation
  doesn't compound across multiple toggles.

## Verdict

- **Metadata source**: `playerConfig.audioConfig.loudnessDb` (prefer
  `perceptualLoudnessDb` when present) from the Innertube `/youtubei/v1/player` response
  for each `videoId` — confirmed field, per-video with a per-format override flag
  (`enablePerFormatLoudness`) whose practical relevance to this app is likely nil (song
  vs video audio doesn't come from alternate formats of the same upload, it comes from
  two entirely different uploads).
- **Injection point**: hook `fetch`/XHR on `/youtubei/v1/player` requests and cache
  `loudnessDb` per `videoId` as responses arrive — this is the standard, proven pattern
  used by real YouTube userscripts for this exact endpoint, fires ahead of playback, and
  doesn't depend on fragile internal player object shape.
- **Formula**: `gainLinear = 10^(-(loudnessDb(new) - loudnessDb(old)) / 20)`, applied
  multiplicatively on top of the user's volume slider via `video.volume`, **clamped to
  ≤ 1.0** (i.e. only ever attenuate). Sign convention should be verified once against a
  real ATV/OMV pair's logged values before trusting it in production — the direction
  (positive = louder, attenuate-only ceiling behavior) is well-supported by independent
  sources, but no authoritative spec confirms it, only reverse-engineering consensus.
- **No-boost handling**: when the incoming stream is the quieter one, don't attempt to
  compensate — there's no gain path available on a CORS-tainted media element without
  Web Audio (which is unavailable here per the existing project constraint). Accept the
  residual perceived dip in that direction; only the louder-incoming case is fixable with
  `video.volume` alone.
