# Fullscreen Visualizer Control Bar + Idle Auto-Hide — Design Spec

**Date:** 2026-06-30
**Status:** Codex review PASS (2 rounds) — ready for implementation planning. Buffering bar
intentionally out of v1.
**Feature branch:** TBD (feature branch + PR per repo convention)
**Builds on:** `2026-06-29-milkdrop-visualizer-design.md` (Task 10 fullscreen control)

## 1. Goal

Give the **fullscreen visualizer** a bottom control bar with the same look and behavior as
YT Music's native **video** player bar, plus a modern **idle auto-hide** pattern that applies to
**both** the visualizer fullscreen and the native video fullscreen. Screenshot #33 (visualizer
fullscreen) currently shows no controls; screenshot #32 (video fullscreen) is the visual
reference the new bar must match.

## 2. Root constraint (established from the code)

The fullscreen element is `_canvasHost` (a `position:fixed` overlay). In fullscreen, only that
element and its descendants render — YT's real player bar lives outside it and is therefore
invisible. **Any bar shown in visualizer fullscreen must be a child of `_canvasHost`.**

Consistent with `visualizer.js`'s established philosophy (clone/proxy YT controls rather than
reparent its fragile web components — e.g. the Visualizer segment is a deep clone, preset-skip
proxies canvas clicks), the bar **drives YT's real controls; it does not replace playback logic**.
Transport is client-side JS on `<video>` + `mediaSession` + best-effort proxy clicks of YT's
player-bar buttons.

**Native dependency:** enter-fullscreen already bounces through the existing native bridge
(`postVizAction('enterFullscreen')` → native re-issues `requestFullscreen` without transient
activation, because a gesture-initiated `requestFullscreen()` is rejected in WKWebView). This
feature **reuses that bridge unchanged**; exit is client-side (`exitFullscreen`). **No Swift feature
logic changes.** The one mechanical touch: the pure-logic module (§4.1) ships as a new bundled JS
file. The `Resources/visualizer/` folder is an Xcode 16 `PBXFileSystemSynchronizedRootGroup`, so a
new `.js` there is auto-bundled — **no `project.pbxproj` edit** — plus one line added to the
`vizScripts` array in `YouTubeMusicWebView.swift` (injected before `visualizer.js`). Confirm the
enter-fullscreen flow still works in QA.

## 3. Decisions (locked via brainstorming)

| Decision | Choice |
|---|---|
| Control set | **Transport + presets**: Prev / Play-Pause / Next, scrubbable seek + time, thumbnail + title/artist, volume, preset ⟨◀ name ▶⟩, exit-fullscreen |
| Bar visibility | **Fullscreen only** (same as YT video). Windowed now-playing keeps today's hover FS button; no bottom bar. |
| Preset name (windowed) | Move today's bottom-center toast → **top-center** of the visualization |
| Preset name (fullscreen) | **Folded into the bar** (no toast); truncated with ellipsis; full name in `title`/`aria-label` |
| Styling | **Match YT's native video bar exactly.** Shared elements look identical; new preset controls reuse the native icon style, sizing, hover, and layout so they read as native. |
| Idle auto-hide scope | Applies to **both** surfaces: our bar (visualizer) **and** YT's real `ytmusic-player-bar` (native video fullscreen), via one shared controller |
| Idle timeout | **2500 ms** |
| Transport wiring | Proxy-click YT's real player-bar buttons (best-effort selectors) with `<video>` play/pause fallback; seek/volume via `<video>`; title/thumb via `mediaSession.metadata` |
| Native changes | **None expected**, but contingent on the existing enter-fullscreen bridge — verify in QA (see §2) |

## 4. Architecture

All new code lives in `youtube-music-player/Resources/visualizer/visualizer.js`, extending the
Task 10 fullscreen module. No new files (except one harness check). Three units:

### 4.1 `createIdleController(opts)` — pure state machine (isolated, testable)

No DOM dependency. Owns the single 2500 ms timer, movement threshold, locks, and grace flag.

```
createIdleController({ timeout=2500, threshold=8, grace=500, onShow, onHide })
  → { activity(x, y), reveal(), setLock(name, bool), destroy() }
```

- `activity(x, y)`: ignore if delta from last (x, y) < `threshold`; else `reveal()`.
- `reveal()`: `onShow()`, clear timer, and re-arm the hide timer **unless any lock is held**.
  Used for non-positional activity too (pointerdown, control keys, focus, peek-zone entry).
- `setLock(name, bool)`: named locks `{ hover, focus, scrub }`. While ANY lock is true, the timer
  is cleared and no hide fires; setting the last lock false re-arms via `reveal()`.
- After an auto-hide, a `justHidden` window (`grace` ms) makes the next `activity()` ignore
  sub-threshold synthetic moves (fullscreen entry + reflow fire spurious `mousemove`). `justHidden`
  never blocks `reveal()` from pointerdown/key/focus — only positional `activity()`.
- `destroy()`: clears timers, resets locks. Idempotent.

**Lock lifecycle (adapter's job, called out so it isn't dropped):**
- `hover`: bar `pointerenter` → `setLock('hover', true)`; `pointerleave` → false. Set **only from
  the bar element**, never from the peek zone (parking in the peek zone must not pin the bar).
- `focus`: `focusin` on a bar control → `reveal()` + `setLock('focus', true)`; `focusout` leaving
  the bar (relatedTarget not in bar) → false.
- `scrub`: seek `pointerdown` → true. Released on `pointerup` / `pointercancel` /
  `lostpointercapture` / window `blur`, all bound at **document/window** level (a scrub can end
  with the pointer released outside the bar; without these the bar strands visible forever).

### 4.2 Chrome adapters (thin; wire the controller to a surface)

Bound on both `fullscreenchange` **and** `webkitfullscreenchange`. Read the fullscreen element as
`document.fullscreenElement || document.webkitFullscreenElement` everywhere (the existing FS code
already listens to both prefixed events — match it). Exactly one adapter active at a time:

- **Visualizer adapter** — chosen when the fullscreen element **is `_canvasHost`** (identity
  check, the reliable signal):
  `onShow` = reveal bar + scrim, `cursor:auto` on host. `onHide` = fade bar + scrim, `cursor:none`.
- **Video adapter** — chosen when a fullscreen element exists and it is **not `_canvasHost`**
  (YT native video fullscreen; the element may be the `<video>`, a YT container, or the doc — we do
  not depend on which):
  - State is applied to a **stable root that is an ancestor of both the video and the bar** —
    `document.documentElement` (with the `.milkviz-idle` class), **not** the fullscreen element
    (which may be a `<video>` that doesn't contain `ytmusic-player-bar`).
  - `onHide` = add `.milkviz-idle` on `<html>`; CSS force-hides YT's real bar and sets the cursor
    (selector + `!important` details in §7). `onShow` = remove it.
  - **The exact YT fullscreen chrome selector is a QA spike, not an assumption.** `ytmusic-player-bar`
    is the windowed bar; YT's *video-fullscreen* chrome may be a different subtree (possibly inside
    a shadow root, which CSS from `<head>` cannot pierce). Plan step: confirm the real selector on
    the live app; if it's shadow-encapsulated, fall back to toggling the element's own
    `[hidden]`/style via JS instead of a stylesheet rule. **Do not ship the video adapter on an
    unverified selector.**
  - ponytail: co-exists with YT's own ~3 s auto-hide — ours fires earlier at 2500 ms. Removing
    `.milkviz-idle` only lifts *our* forced hide; it does not force YT's bar visible, so YT's own
    reveal-on-move must still work. If the spike shows YT suppresses its bar independently of our
    class, treat that as a follow-up finding rather than fighting it in v1.

Activity listeners (`mousemove` with threshold, `pointerdown`, control `keydown`, `focusin`,
bottom-edge peek zone) are attached at the document level while any element is fullscreen, removed
on exit. Both adapters drive the same `createIdleController` instance. The peek zone feeds
`reveal()` only — it never sets the `hover` lock (§4.1).

### 4.3 Player bar (visualizer only) — child of `_canvasHost`, `position:absolute; bottom:0`

**Structure requirement:** the bar is a **direct child of `_canvasHost` and a SIBLING of the
canvas — never inside the canvas subtree.** The capture-phase preset-skip interceptor
(`_onDocClickCapture`) only eats clicks where `MilkViz.canvas.contains(e.target)`, so a sibling bar
passes through untouched (same trick the FS button already relies on). Bar gets a higher z-index
than the canvas and `pointer-events:auto`; individual controls `stopPropagation` as belt-and-braces.

**Active media element:** do not trust `document.querySelector('video')` blindly — YT Music can
have multiple/detached/ad/preload `<video>` elements. Resolve the **active** one (playing, or the
one `mediaSession` reflects, or largest visible with a valid `duration`) and **re-resolve on
`play`/`loadedmetadata`/track-change**. Guard all time math against `duration` being `NaN`,
`Infinity`, or `0` (render seek as empty/disabled until valid); clamp seek targets into
`[0, duration]`.

Layout mirrors YT's native video bar:

```
▁▁▁▁▁▁▁▁▁ seek track (thin, full width, red progress, scrubbable) ▁▁▁▁▁▁▁▁▁
[⏮ ⏯ ⏭]  0:25 / 4:53    🖼 Title — Artist          🔊 vol   ⟨ ◀ PresetName ▶ ⟩   ⤢
```

| Element | Source of truth / action |
|---|---|
| Prev / Play-Pause / Next | **primary:** proxy-click YT player-bar buttons via best-effort selectors (prev/next have no `<video>` equivalent). **Fallback:** play-pause → active `<video>.play()/pause()`; prev/next → **hidden** if their button isn't found (never a dead control). Acceptance: selectors confirmed in QA; play icon reflects `<video>.paused` (source of truth), not YT's button state, to avoid desync. |
| Seek track + time | read/write the **active** `<video>` `.currentTime` / `.duration` (see resolution above); drag sets `scrub` lock. Buffering bar: **omitted in v1** (render played + track only); revisit with `video.buffered` later. |
| Volume | active `<video>.volume`; mute toggle reflects `aria-pressed` off `<video>.muted` |
| Thumbnail + title/artist | `navigator.mediaSession.metadata` (`.title`, `.artist`, `.artwork`). **Fallbacks:** missing artwork → hide the thumbnail slot (no broken-image box); missing title → last known title or empty (never render "undefined"). |
| Preset ⟨◀ name ▶⟩ | call existing `doLoadPreset(±1)`; label updates on every preset change, truncated with `max-width`+ellipsis, full name in `title`/`aria-label` |
| Exit-fullscreen (⤢) | `document.exitFullscreen()`; the top-right FS button is suppressed while in fullscreen |

State sync: bind on the **active** `<video>` — `timeupdate` (seek/time), `play`/`pause` (icon),
`volumechange` (volume/mute); rebind when the active element is re-resolved. Reuse the existing 3 s
track poll (`_checkTrack`) for title/thumb. No new polling loop.

## 5. Visuals & motion (from 2026 research synthesis)

- **Match reference (#32):** same glyphs/stroke weights, spacing, thin red progress line,
  `M:SS / M:SS` time format, thumbnail+title treatment. New preset controls use identical icon
  style, size, and hover treatment.
- **Scrim:** bottom eased gradient (multi-stop, ~30% of viewport height) behind the bar; fades
  *with* the bar — never a permanent band over idle art.
- **Reveal:** ~180 ms, `opacity 0→1` + `translateY(10px→0)`, ease-out `cubic-bezier(.16,1,.3,1)`
  (snappy).
- **Hide:** ~350 ms ease-in, then `visibility:hidden` after transition (gentle).
- **Cursor:** same timer sets `cursor:none` when idle.
- **Peek-on-approach:** entering the bottom ~15% edge zone counts as activity (subtle reveal).

## 6. Accessibility

- Controls stay in the DOM (opacity/visibility, never `display:none`); `visibility:hidden` applied
  only after the fade, flipped back the instant `focusin` fires.
- `focusin` reveals + holds (focus lock), like hover-lock. Focus rings kept (never `outline:none`).
- `aria-label` / `aria-pressed` on play-pause and mute, updated on state change. Preset label
  `aria-live="polite"`.
- `prefers-reduced-motion`: drop `translateY`, ~0 ms transitions; hide *behavior* preserved. The
  adapters must also skip any delayed-visibility choreography (the post-fade `visibility:hidden`
  flip) when transitions are zero-duration, or the bar can get stuck.

## 7. Theming (LightThemeEngine survival)

The bar sits over the dark visualizer canvas → force white-on-dark inline with `!important`,
including `-webkit-text-fill-color`, exactly as `showToast` already does (see the existing toast
comments). Applies to text, icons, and time.

The video adapter needs no *color* forcing (it's YT's own bar), but the **hide rule itself must
win** against YT's hostile inline/style environment: the `.milkviz-idle <bar-selector>` rule sets
`opacity`, `visibility`, `pointer-events`, and (on the root) `cursor` all with `!important`, and
the selector must be specific enough to beat YT's inline styles. If the spike (§4.2) finds the
chrome is shadow-encapsulated, forcing via JS style on the element replaces the stylesheet rule.

## 8. Lifecycle & teardown

- Bar + idle listeners created in/around `addFullscreenControl`; torn down in
  `removeFullscreenControl` and on `setActive(false)` — no timer/listener/DOM survives the
  visualizer being off or fullscreen being exited.
- `_fsChangeHandler` extends to: pick the adapter, show/hide the bar (bar only exists in
  visualizer fullscreen), and start/stop the shared activity listeners.
- The `.milkviz-idle` class is removed from `<html>` on fullscreen exit so YT's video bar returns
  to YT's own control.

**Repeated enter/exit is where leaks show — every listener has one named owner, all removed on
exit:** document `mousemove`/`pointerdown`/`keydown`/`focusin`; document/window scrub-release
(`pointerup`/`pointercancel`/`lostpointercapture`/`blur`); the peek-zone hit-test (folded into the
single `mousemove` handler, not a second listener); the bar's own `pointerenter`/`pointerleave`/
`focusin`/`focusout`; the active `<video>` media events (`timeupdate`/`play`/`pause`/`volumechange`,
re-bound on re-resolve, old element unbound first); and `fullscreenchange`/`webkitfullscreenchange`.
Use add-after-remove (the file's existing idempotency pattern) so re-entry can't double-bind. The
idle controller's `destroy()` is called on every fullscreen exit.

## 9. Preset label routing

`doLoadPreset` calls a new `announcePreset(name)` that routes by state:
- Visualizer **fullscreen** → update the bar's preset label (truncated).
- Visualizer **windowed** → top-center toast (relocated from today's bottom-center `showToast`).

## 10. Testing

ponytail: one runnable **automated** check + a manual checklist for the DOM/fullscreen parts that
can't run headlessly.

- **Automated (`harness/`):** `createIdleController` is pure — assert sub-`threshold` movement does
  **not** reveal; any lock blocks hide; releasing the last lock re-arms; `reveal()` from
  pointerdown/focus ignores the `justHidden` grace; `destroy()` clears everything. No DOM, no
  framework.
- **Manual QA checklist (the riskiest, non-headless paths):** repeated fullscreen enter/exit leaves
  no leaked listeners/timers (bar reveals/hides correctly each cycle); native **video** fullscreen
  detection + selector actually hides YT's bar and restores it on exit; bar button clicks reach the
  bar (not eaten by `_onDocClickCapture`); scrub started in-bar and released **outside** the bar
  releases the lock; the `.milkviz-idle` class and CSS are gone after exit; preset label truncates
  without overflow; enter-fullscreen still works via the existing native bridge (§2).

## 11. Out of scope (skipped, add later if wanted)

- Reparenting YT's bar into fullscreen (unwanted buttons, no preset controls, breaks web
  components).
- Like/dislike, CC, ⋮ menu, shuffle, repeat (not in the chosen control set).
- Beat-synced chrome glow, velocity-based reveal (research: gimmicky / tests poorly).
- Our custom bar over native video (rejected in favor of driving YT's real bar).
