# Visualizer headline asset — technical research (July 2026)

## Verdict

Ship **one optimized full-page GIF** as the README hero (the whole now-playing page baked
into a single GIF where only the visualizer stage animates), plus a **muted looping MP4/WebM
and an animated WebP** of the same capture for the landing page / App Store / social. The GIF
is not chosen because it's good — it's the *only* animated format GitHub README markdown plays
inline on its own, and a README is the primary target. Keep it light with tight discipline
(≈960 px wide, 12 fps, ~4 s, `gifsicle -O3` so the static chrome costs almost nothing after
frame 1) → realistic **2–4 MB**. The whole-page **SVG option (B) is a bad idea — reject it**
(details below). Do **not** two-layer for README (markdown gives you one image, no overlay);
two-layer only makes sense on your own HTML landing page.

---

## 1. Format shootout for the animating region

Content is the worst case for palette formats: colorful, full-frame WebGL motion, thousands of
colors changing every frame. That's exactly what GIF is bad at and what video codecs are great at.

| Format | ~4 s colorful full-motion, ~960 px | Loop | Animates inline in **GitHub README md**? | Other embed targets | Verdict |
|---|---|---|---|---|---|
| **GIF** | 2–4 MB (full page, gifsicle-optimized) / <1.5 MB (viz-crop only) | infinite, seam unless faded | **Yes — the only reliable one** | Everywhere (universal) | **README winner by necessity** |
| **Animated WebP** | 400 KB–1 MB (lossy q70) | infinite, clean | **No** — GitHub added *static* WebP Aug 2025; animation is **not** documented and not reliably played inline. Shows first frame. | Landing page, modern browsers | Great for web, unreliable for README animation |
| **APNG** | 3–8 MB (lossless-ish; huge here) | infinite | **No** — served as PNG, GitHub's image proxy shows first frame | niche | **Skip** — biggest files, no README payoff |
| **AVIF sequence** | 200–600 KB (best compression) | infinite | **No** | some browsers | Best ratio, worst support; not worth it here |
| **Muted MP4 (h264) / WebM (vp9)** | 150–500 KB | infinite (`loop`) | **No** as `![]()`. GitHub only plays video you **drag-drop into the web editor** (→ click-to-play player with controls, *not* autoplay-loop). | Landing page `<video autoplay muted loop playsinline>`, App Store previews, social | **Best quality/size** — but not an inline auto-animation on README |

**Constraint that decides everything:** GitHub sanitizes README markdown; **only animated GIF
plays inline on its own.** WebP/APNG render as their first frame; video becomes a click-to-play
player at best. So if the headline must auto-animate in the README, it must be a GIF. Everything
else is a companion asset for surfaces you control.

**Size ceiling before a README feels heavy:** keep the hero **under ~4–5 MB** (GitHub hard-caps
inline images at 10 MB and stops animating past that, but 5 MB already feels sluggish on a phone).
Our discipline levers, in order of impact: (1) shorter duration, (2) lower fps, (3) smaller
dimensions, (4) a *flowing* preset rather than a strobing/noisy one (smooth motion inter-frame-
compresses far better), (5) `gifsicle -O3 --lossy`.

## 2. Compositing: bake one asset, don't two-layer (for README)

- **README → bake into ONE GIF.** Markdown gives you a single `<img>`; you cannot position an
  animated layer over a static PNG (GitHub strips the CSS/positioning that would require). So the
  static chrome and the moving viz must live in the same file. This is *fine*: the YT Music
  light-mode chrome is mostly flat off-white + text — GIF's **good** case — and with `gifsicle -O3`
  inter-frame optimization, frame 1 carries the whole page once and every later frame stores only
  the changed viz rectangle. The chrome is effectively free; the viz-rect delta × N frames is the
  whole budget.
- **Landing page → two-layer.** On your own HTML, keep a crisp static PNG of the page and overlay
  a small `<video autoplay muted loop>` (or animated WebP) positioned over the canvas rect. Far
  smaller and sharper than any full-page GIF. Use this where you control the markup.

## 3. The SVG option (B) — reject it

An SVG *can* embed an animated raster (`<image href="data:image/webp;base64,…">` and the browser
animates it), so it's technically possible. It's still the wrong tool here:

1. **Zero byte savings.** The animated raster *is* the payload; wrapping it in SVG only adds
   markup overhead. There is no vector content to save on — the "chrome" is a screenshot (raster),
   not vectors.
2. **GitHub kills it anyway.** README SVGs go through the camo image proxy, which commonly
   rasterizes/sanitizes them to a static PNG — your embedded animation dies, and scripts are
   stripped. So it fails on the one target that matters.
3. **Pure added complexity** for a hand-built XML wrapper around assets you already have.

The only world where SVG wins is crisp *vector* UI text over a small animated region — and our
chrome is a bitmap screenshot, so that world doesn't apply. **Over-engineering; don't build it.**

## 4. Capturing real Butterchurn frames

Good news: `harness/fixtures/screenshots.mjs` **already renders the app's real vendored Butterchurn
+ preset pack headlessly in WebKit** and screenshots it (that's how `screenshots/visualizer.png`,
4.8 MB, is produced). Headless WebKit renders the WebGL2 viz fine on this machine. We extend that
one-still path to an N-frame capture.

- **Audio:** headless WebKit has no AudioWorklet (the app's native PCM path), so — exactly as the
  existing generator does — drive Butterchurn directly with a synthetic looping noise `BufferSource`
  → `GainNode` → `viz.connectAudio()`. Same engine + presets users see; the motion is authentic.
- **Determinism:** not required. This is a marketing loop, not a regression baseline (the generator
  already notes "the bloom is non-deterministic, fine for a marketing image"). So **realtime rAF
  render + screenshot on a fixed cadence** is the right, lazy call. Full frame-locking (render from
  stored FFT samples, VFR→CFR remux) exists — see Neuburger's prerender writeup — but it's for
  100 GB full-song YouTube videos and is massive overkill for a 4 s loop. Skip it.
- **Capture mechanism:** use **`page.screenshot`** clipped to the page/stage, N times on a timer.
  It reads back through the OS compositor, so it works regardless of `preserveDrawingBuffer`.
  Avoid `canvas.toDataURL()` on the WebGL canvas — Butterchurn creates its GL context without
  `preserveDrawingBuffer`, so `toDataURL` can come back blank. `captureStream`+`MediaRecorder`
  is unreliable in headless WebKit — don't. (If frame-capture throughput ever bites, a Chromium
  fallback with `MediaRecorder` is the escape hatch, but WebKit `page.screenshot` is fine here.)
- **Most authentic path — render the real viz *into the real player page*:** open the actual
  now-playing page (reuse `gotoPlayer()` from `lib/player-mock.js`), inject a Butterchurn `<canvas>`
  into the stage rect *instead of* `viz-still.jpg`, start the noise-driven render loop, then take N
  **full-page** screenshots. Because nothing else on the page moves, the chrome is automatically
  static and the viz is automatically real — **no compositing step at all**, the frames are already
  the finished composite. This is the least-code, most-authentic option and reuses the exact
  Butterchurn-injection block already in `screenshots.mjs`.
- **Loop:** Butterchurn doesn't self-loop. Ship it with `loop=infinite` and accept a soft seam
  (the eye forgives busy motion) — that's the lazy default. If the seam reads badly, add a ~0.4 s
  crossfade of the tail into the head in ffmpeg (`xfade`), or pick a preset whose motion is near-
  cyclic. Don't boomerang (looks unnatural on flow fields).

## 5. Encoding pipeline & commands

**Installed now:** `ffmpeg` 8.0.1, `gifsicle`, `img2webp` (libwebp), `cwebp`, `gif2webp`.
**Install for best GIF quality:** `brew install gifski pngquant` (gifski's quantizer beats
ffmpeg palettegen on colorful gradients). Commands below give a gifski path *and* an ffmpeg-only
fallback so nothing new is strictly required.

Assume frames captured as `frames/f-%04d.png` at 12 fps, page ~960 px wide.

**GIF — gifski (best looking), then gifsicle to strip inter-frame redundancy:**
```bash
gifski --fps 12 --width 960 --quality 80 -o viz-headline.raw.gif frames/f-*.png
gifsicle -O3 --lossy=60 --colors 200 viz-headline.raw.gif -o viz-headline.gif
```

**GIF — ffmpeg-only fallback (no gifski/pngquant needed):**
```bash
# one shared palette from the diff of frames = better on mostly-static pages
ffmpeg -framerate 12 -i frames/f-%04d.png \
  -vf "scale=960:-1:flags=lanczos,palettegen=stats_mode=diff:max_colors=200" -y palette.png
ffmpeg -framerate 12 -i frames/f-%04d.png -i palette.png \
  -lavfi "scale=960:-1:flags=lanczos [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -y viz-headline.raw.gif
gifsicle -O3 --lossy=60 viz-headline.raw.gif -o viz-headline.gif   # frame-diff optimize
```
`diff_mode=rectangle` + `gifsicle -O3` are what make the static chrome cost ~nothing after frame 1.
`--lossy` on gifsicle is the single biggest size lever after fps/dimensions.

**Animated WebP (landing page; tiny, clean loop):**
```bash
img2webp -loop 0 -d 83 -lossy -q 70 frames/f-*.png -o viz-headline.webp   # 83 ms ≈ 12 fps
```

**Muted looping MP4 + WebM (landing page `<video>`, App Store, social):**
```bash
# H.264 MP4 — widest playback (dimensions even for yuv420p)
ffmpeg -framerate 12 -i frames/f-%04d.png -vf "scale=960:-2:flags=lanczos" \
  -c:v libx264 -crf 24 -pix_fmt yuv420p -movflags +faststart -an -y viz-headline.mp4
# VP9 WebM — smaller, for modern browsers
ffmpeg -framerate 12 -i frames/f-%04d.png -vf "scale=960:-2:flags=lanczos" \
  -c:v libvpx-vp9 -crf 34 -b:v 0 -an -y viz-headline.webm
```

**Optional seamless loop (only if the seam bugs you)** — crossfade last 0.4 s into the head before
encoding, applied to the mp4/webm (GIF can use the same filtered frames):
```bash
ffmpeg -i viz-headline.mp4 -vf "loop=loop=1:size=1:start=0,tblend,... " ...   # simpler: re-capture ~0.4s extra and xfade tail→head
```
Ponytail: don't build this unless QA says the seam shows.

## 6. Expected output sizes (≈960 px, 12 fps, ~4 s, flowing preset)

| Asset | Target size |
|---|---|
| `viz-headline.gif` (full page, gifsicle-optimized) | **2–4 MB** |
| `viz-headline.gif` (cropped to viz rect only, ~640 px) | <1.5 MB |
| `viz-headline.webp` (animated, lossy q70) | 400 KB–1 MB |
| `viz-headline.mp4` (h264 crf24) | 150–400 KB |
| `viz-headline.webm` (vp9 crf34) | 120–300 KB |
| APNG | 3–8 MB — don't ship |

If the GIF lands over ~4 MB: drop to 10 fps, trim to 3 s, or scale to 800 px — in that order.

## 7. Step-by-step implementation plan for THIS repo

Everything lives in `harness/` and reuses existing machinery. **One new script + one npm target.**

1. **Add `harness/fixtures/viz-headline.mjs`** (new marketing capture — model it on the existing
   Butterchurn block in `screenshots.mjs` lines 213–249 and `gotoPlayer()` in `lib/player-mock.js`):
   - Launch headless WebKit, `viewport 1312×912`, `deviceScaleFactor 2`, `colorScheme:'light'`,
     `installFixture(ctx)` + inject the light engine (mirror `screenshots.mjs` header).
   - `gotoPlayer(page, BASE)` to land on the real now-playing page; hide promo/toast chrome (already
     done inside `gotoPlayer`).
   - `page.evaluate`: remove any `#mock-stage`, find the stage element (`ytmusic-player`), inject a
     `<canvas>` sized to the stage rect, `addScriptTag` the app's vendored `butterchurn.min.js` +
     `butterchurnPresets.min.js` (paths as in `screenshots.mjs`), build the noise `BufferSource → gain
     → viz.connectAudio`, `loadPreset` a well-reading flowing preset (reuse `'Flexi - infused with the
     spiral'`), start a `requestAnimationFrame` render loop.
   - Loop N times (e.g. 48 frames): `await page.waitForTimeout(83)` then `await page.screenshot({ path:
     scratch/f-XXXX.png })` (full page, or `clip` to the page rect to trim dead margins).
   - `child_process.execFileSync` the ffmpeg/gifsicle/img2webp commands from §5 to emit
     `screenshots/viz-headline.gif`, `.webp`, `.mp4`, `.webm`.
   - Clean up the temp frame dir. Log final byte sizes (reuse the `record()` size-log style already
     in `screenshots.mjs`).
2. **Add npm script** to `harness/package.json`: `"viz-headline": "node fixtures/viz-headline.mjs"`.
3. **README:** embed `![Butterchurn visualizer](screenshots/viz-headline.gif)`. Keep the crisp
   static `screenshots/player-visualizer.png` as the fallback/OG image.
4. **Landing page (when it exists):** use `<video autoplay muted loop playsinline poster="…">` with
   the mp4/webm, or the animated webp — never the GIF.
5. Frames go to the session scratchpad or a gitignored temp dir — **do not** commit PNG frames; only
   commit the final small assets.

Reused as-is: `installFixture`, the light-engine injection, `gotoPlayer()`, the Butterchurn
script-injection + noise-audio pattern, the size-logging convention. Net new code ≈ one ~120-line
script; no new runtime dependency (gifski/pngquant optional quality upgrade).

## 8. Open questions for the user

1. **Primary target confirm:** is the GitHub README the main home for this? That's the only reason
   we're constrained to GIF. If it's really a landing page / App Store, we lead with MP4/WebP and the
   GIF becomes optional — much smaller and sharper.
2. **Full page vs. viz-region crop in the README:** full-page (chrome + toggle visible, ~2–4 MB) or a
   tighter crop of just the visualizer stage (<1.5 MB, loses the surrounding UI story)? The brief says
   full page — confirming because it's the biggest size lever.
3. **GIF budget:** hard ceiling? (Recommend ≤4 MB. If you want ≤2 MB, we go 10 fps / 3 s / 800 px.)
4. **Install `gifski` + `pngquant`?** ~2 better-looking GIF at the same size. Optional — ffmpeg-only
   path works today. (Global brew installs — flagging per your "ask before global installs" rule.)
5. **Seamless loop:** accept a soft seam (default), or spend the extra step on a tail→head crossfade?
6. **Preset:** lock one flowing preset for brand consistency, or let it pick from the curated list?
