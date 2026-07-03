# Fullscreen Visualizer Control Bar + Idle Auto-Hide — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the fullscreen visualizer a bottom control bar matching YT Music's native video bar, plus a modern idle auto-hide that also governs YT's native video fullscreen.

**Architecture:** Pure control logic (idle state machine + small media helpers) ships as a new DOM-free bundled module (`fs-controls-util.js`, injected before `visualizer.js`, unit-tested in Node). All DOM/glue lives in `visualizer.js`, extending its existing Task 10 fullscreen module: a bar built as a sibling of the canvas inside `_canvasHost`, driven by YT's real controls (`<video>` + `mediaSession` + proxy button clicks), plus two thin idle adapters (visualizer bar / native YT bar) selected by which element is fullscreen.

**Tech Stack:** Vanilla ES5-style JS injected as `WKUserScript` (no bundler, no modules in the webview), Butterchurn (existing), Playwright test runner (Node) for the pure-logic unit test, Xcode 16 SwiftUI/WKWebView host.

**Spec:** `docs/superpowers/specs/2026-06-30-fullscreen-control-bar-design.md` (Codex PASS, 2 rounds).

## Global Constraints

- **No webview modules/bundler.** New shared code is a browser-global IIFE assigning to `window`/`self` (like every existing viz script). New file is injected via a `vizScripts` entry in `YouTubeMusicWebView.swift`, **before** `visualizer.js`.
- **No `project.pbxproj` edit.** `Resources/visualizer/` is a `PBXFileSystemSynchronizedRootGroup` — a new `.js` there is auto-bundled. Verify by build; if (unexpectedly) not bundled, that's the only case needing a pbxproj entry.
- **Bar must be a direct child of `_canvasHost` and a SIBLING of `MilkViz.canvas`** — never inside the canvas subtree — so the capture-phase `_onDocClickCapture` (which only eats `MilkViz.canvas.contains(e.target)`) leaves bar clicks alone.
- **Fullscreen element reads use `document.fullscreenElement || document.webkitFullscreenElement`**, and listen to both `fullscreenchange` and `webkitfullscreenchange` (match existing `_fsChangeHandler`).
- **LightThemeEngine survival:** anything over the dark canvas forces white with inline `!important` incl. `-webkit-text-fill-color` (copy `showToast`'s pattern). The native-video hide rule forces `opacity/visibility/pointer-events`/`cursor` with `!important` and a selector specific enough to beat YT inline styles.
- **Idle timeout 2500 ms; movement threshold 8 px; post-hide grace 500 ms.**
- **Bar appears only in visualizer fullscreen.** Windowed keeps today's hover FS button. Buffering bar out of v1.
- **Node/nvm:** before any `npm`/`node`, run `source ~/.nvm/nvm.sh && nvm use` (repo default Node 22).
- **Commit style:** brief imperative, no Co-Authored-By trailers.

---

## File Structure

- **Create** `youtube-music-player/Resources/visualizer/fs-controls-util.js` — DOM-free: `createIdleController`, `formatTime`, `clampSeek`, `pickActiveVideo`; exposes `window.MilkVizCtl`.
- **Create** `harness/tests/fs-controls-util.spec.js` — Node unit test (Playwright runner, no browser) for the four pure functions.
- **Modify** `youtube-music-player/YouTubeMusicWebView.swift:332-337` — add `("fs-controls-util", "visualizer")` as the first `vizScripts` entry.
- **Modify** `youtube-music-player/Resources/visualizer/visualizer.js` — bar DOM + styling, idle adapters, transport wiring, preset-label routing, teardown (Tasks 2-6).

---

## Task 1: Pure control module + unit test + injection

**Files:**
- Create: `youtube-music-player/Resources/visualizer/fs-controls-util.js`
- Test: `harness/tests/fs-controls-util.spec.js`
- Modify: `youtube-music-player/YouTubeMusicWebView.swift:332-337`

**Interfaces:**
- Produces: `window.MilkVizCtl = { createIdleController, formatTime, clampSeek, pickActiveVideo }`
  - `createIdleController({ timeout=2500, threshold=8, grace=500, onShow, onHide, setTimer=setTimeout, clearTimer=clearTimeout }) → { activity(x,y), reveal(), setLock(name,bool), destroy(), isVisible() }`
  - `formatTime(seconds) → "M:SS" | "H:MM:SS"` ("0:00" for NaN/Infinity/negative)
  - `clampSeek(t, duration) → number | null` (null when duration invalid)
  - `pickActiveVideo(videos) → HTMLVideoElement | null`

- [ ] **Step 1: Write the failing test** — `harness/tests/fs-controls-util.spec.js`

```js
import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

// The module is a browser-global IIFE (assigns to `self.MilkVizCtl`). Load it into a
// sandbox so this stays a pure Node test — no webkit, no DOM.
const SRC = readFileSync(
  fileURLToPath(new URL('../../youtube-music-player/Resources/visualizer/fs-controls-util.js', import.meta.url)),
  'utf8');
function loadCtl() {
  const sandbox = { self: {} };
  vm.runInNewContext(SRC, sandbox);
  return sandbox.self.MilkVizCtl;
}

// Deterministic timers keyed by delay: hide uses `timeout`, grace uses `grace`.
function fakeTimers() {
  let id = 0; const timers = new Map();
  return {
    setTimer: (fn, ms) => { const i = ++id; timers.set(i, { fn, ms }); return i; },
    clearTimer: (i) => timers.delete(i),
    fireByMs: (ms) => { for (const [i, t] of timers) { if (t.ms === ms) { timers.delete(i); t.fn(); return true; } } return false; },
  };
}

test('sub-threshold move does not reveal; first real move does', () => {
  const { createIdleController } = loadCtl();
  let shows = 0; const tm = fakeTimers();
  const c = createIdleController({ onShow: () => shows++, setTimer: tm.setTimer, clearTimer: tm.clearTimer });
  c.activity(100, 100);
  c.activity(103, 100); // dx=3 < 8 -> ignored
  expect(shows).toBe(1);
  expect(c.isVisible()).toBe(true);
});

test('any lock blocks the hide timer', () => {
  const { createIdleController } = loadCtl();
  let hides = 0; const tm = fakeTimers();
  const c = createIdleController({ onHide: () => hides++, setTimer: tm.setTimer, clearTimer: tm.clearTimer });
  c.activity(0, 0);
  c.setLock('hover', true);
  expect(tm.fireByMs(2500)).toBe(false);
  expect(hides).toBe(0);
});

test('releasing the last lock re-arms the hide', () => {
  const { createIdleController } = loadCtl();
  let hides = 0; const tm = fakeTimers();
  const c = createIdleController({ onHide: () => hides++, setTimer: tm.setTimer, clearTimer: tm.clearTimer });
  c.activity(0, 0);
  c.setLock('focus', true);
  c.setLock('focus', false);
  expect(tm.fireByMs(2500)).toBe(true);
  expect(hides).toBe(1);
  expect(c.isVisible()).toBe(false);
});

test('justHidden swallows synthetic post-hide movement; reveal() bypasses it', () => {
  const { createIdleController } = loadCtl();
  let shows = 0, hides = 0; const tm = fakeTimers();
  const c = createIdleController({ onShow: () => shows++, onHide: () => hides++, setTimer: tm.setTimer, clearTimer: tm.clearTimer });
  c.activity(0, 0);
  tm.fireByMs(2500);
  expect(hides).toBe(1);
  c.activity(500, 500); // large synthetic jump during grace -> swallowed
  expect(shows).toBe(1);
  expect(c.isVisible()).toBe(false);
  c.reveal();           // intentional -> reveals despite grace
  expect(shows).toBe(2);
  expect(c.isVisible()).toBe(true);
});

test('destroy() clears the pending hide timer', () => {
  const { createIdleController } = loadCtl();
  let hides = 0; const tm = fakeTimers();
  const c = createIdleController({ onHide: () => hides++, setTimer: tm.setTimer, clearTimer: tm.clearTimer });
  c.activity(0, 0);           // arms a hide timer
  c.destroy();
  expect(tm.fireByMs(2500)).toBe(false);  // hide timer was cleared
  expect(hides).toBe(0);
});

test('formatTime / clampSeek / pickActiveVideo edge cases', () => {
  const { formatTime, clampSeek, pickActiveVideo } = loadCtl();
  expect(formatTime(25)).toBe('0:25');
  expect(formatTime(293)).toBe('4:53');
  expect(formatTime(NaN)).toBe('0:00');
  expect(formatTime(Infinity)).toBe('0:00');
  expect(formatTime(3725)).toBe('1:02:05');
  expect(clampSeek(50, 100)).toBe(50);
  expect(clampSeek(150, 100)).toBe(100);
  expect(clampSeek(-5, 100)).toBe(0);
  expect(clampSeek(50, NaN)).toBe(null);
  expect(clampSeek(50, 0)).toBe(null);
  const vids = [
    { duration: NaN, paused: true, readyState: 0 },              // no duration -> excluded
    { duration: 100, paused: true, ended: false, readyState: 2 },
    { duration: 240, paused: false, ended: false, readyState: 4 }, // playing + valid -> winner
  ];
  expect(pickActiveVideo(vids)).toBe(vids[2]);
  // No video playing -> longest READY valid one (excludes not-yet-loaded preloads).
  const paused = [
    { duration: 200, paused: true, ended: false, readyState: 0 }, // not ready -> excluded
    { duration: 90, paused: true, ended: false, readyState: 3 },
  ];
  expect(pickActiveVideo(paused)).toBe(paused[1]);
  expect(pickActiveVideo([])).toBe(null);
});
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd harness && source ~/.nvm/nvm.sh && nvm use && npx playwright test tests/fs-controls-util.spec.js`
Expected: FAIL — `readFileSync` throws `ENOENT` (the module file doesn't exist yet), so every test errors.

- [ ] **Step 3: Write `fs-controls-util.js`**

```js
// Pure, DOM-free control logic for the fullscreen visualizer bar + idle auto-hide.
// Injected before visualizer.js as window.MilkVizCtl. Kept DOM-free so it unit-tests in
// Node (harness/tests/fs-controls-util.spec.js) without a browser.
(function (root) {
    'use strict';

    // Idle auto-hide state machine. No DOM: the caller wires onShow/onHide to a surface and
    // feeds it activity()/setLock(). Timers injectable so tests drive them deterministically.
    function createIdleController(opts) {
        opts = opts || {};
        var timeout = opts.timeout != null ? opts.timeout : 2500;
        var threshold = opts.threshold != null ? opts.threshold : 8;
        var grace = opts.grace != null ? opts.grace : 500;
        var onShow = opts.onShow || function () {};
        var onHide = opts.onHide || function () {};
        var setTimer = opts.setTimer || setTimeout;
        var clearTimer = opts.clearTimer || clearTimeout;

        var lastX = null, lastY = null;
        var locks = { hover: false, focus: false, scrub: false };
        var hideTimer = null, graceTimer = null;
        var justHidden = false, visible = false;

        function anyLock() { return locks.hover || locks.focus || locks.scrub; }

        function armHide() {
            if (hideTimer !== null) { clearTimer(hideTimer); hideTimer = null; }
            if (anyLock()) return;
            hideTimer = setTimer(doHide, timeout);
        }

        function doHide() {
            hideTimer = null;
            if (anyLock()) return;
            visible = false;
            onHide();
            justHidden = true;  // suppress the synthetic mousemove that fullscreen/reflow fires
            if (graceTimer !== null) clearTimer(graceTimer);
            graceTimer = setTimer(function () { justHidden = false; graceTimer = null; }, grace);
        }

        // Show + (re)arm. Bypasses the justHidden guard: an intentional pointerdown/key/focus
        // must reveal even inside the post-hide grace window.
        function reveal() {
            if (!visible) { visible = true; onShow(); }
            armHide();
        }

        // Positional activity (mousemove). During the grace window, swallow moves (even large
        // synthetic jumps) but keep tracking position; otherwise ignore sub-threshold jitter.
        function activity(x, y) {
            if (justHidden) { lastX = x; lastY = y; return; }
            if (lastX !== null) {
                var dx = x - lastX, dy = y - lastY;
                if (dx * dx + dy * dy < threshold * threshold) return;
            }
            lastX = x; lastY = y;
            reveal();
        }

        function setLock(name, val) {
            if (!(name in locks)) return;
            locks[name] = !!val;
            if (val) { if (hideTimer !== null) { clearTimer(hideTimer); hideTimer = null; } }
            else if (!anyLock()) { armHide(); }
        }

        function destroy() {
            if (hideTimer !== null) { clearTimer(hideTimer); hideTimer = null; }
            if (graceTimer !== null) { clearTimer(graceTimer); graceTimer = null; }
            locks.hover = locks.focus = locks.scrub = false;
            justHidden = false;
        }

        return { activity: activity, reveal: reveal, setLock: setLock, destroy: destroy,
                 isVisible: function () { return visible; } };
    }

    // "M:SS" (or "H:MM:SS" past an hour). NaN/Infinity/negative -> "0:00".
    function formatTime(sec) {
        if (!isFinite(sec) || sec < 0) sec = 0;
        sec = Math.floor(sec);
        var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
        var mm = (h > 0 && m < 10) ? '0' + m : '' + m;
        var ss = s < 10 ? '0' + s : '' + s;
        return h > 0 ? h + ':' + mm + ':' + ss : mm + ':' + ss;
    }

    // Clamp a seek target into [0, duration]. Invalid duration -> null (caller disables seek).
    function clampSeek(t, duration) {
        if (!isFinite(duration) || duration <= 0) return null;
        if (!isFinite(t) || t < 0) return 0;
        return t > duration ? duration : t;
    }

    // Pick the active media element: prefer a playing one; else the longest one; else null.
    // "Valid" = finite positive duration AND readyState >= 1 (HAVE_METADATA) — this excludes
    // detached/ad/preload elements that have no loaded media yet. (readyState may be undefined
    // for plain test doubles; treat undefined as valid so pure tests can omit it.)
    function pickActiveVideo(videos) {
        var list = videos ? Array.prototype.slice.call(videos) : [];
        var valid = list.filter(function (v) {
            return v && isFinite(v.duration) && v.duration > 0 &&
                   (v.readyState === undefined || v.readyState >= 1);
        });
        if (!valid.length) return null;
        var playing = valid.filter(function (v) { return !v.paused && !v.ended; });
        var pool = playing.length ? playing : valid;
        return pool.reduce(function (best, v) { return (best && best.duration >= v.duration) ? best : v; }, null);
    }

    root.MilkVizCtl = { createIdleController: createIdleController, formatTime: formatTime,
                        clampSeek: clampSeek, pickActiveVideo: pickActiveVideo };
})(typeof self !== 'undefined' ? self : this);
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `cd harness && source ~/.nvm/nvm.sh && nvm use && npx playwright test tests/fs-controls-util.spec.js`
Expected: PASS — 6 passed.

- [ ] **Step 5: Register the module in Swift** — `YouTubeMusicWebView.swift`, in the `vizScripts` array (currently lines 332-337), add `fs-controls-util` as the FIRST entry so it loads before `visualizer.js`:

```swift
        let vizScripts: [(String, String?)] = [
            ("fs-controls-util",       "visualizer"),
            ("butterchurn.min",        "visualizer"),
            ("butterchurnPresets.min", "visualizer"),
            ("preset-list",            "visualizer"),
            ("visualizer",             "visualizer"),
        ]
```

- [ ] **Step 6: Build and verify the module bundles**

Run: `xcodebuild -list -project youtube-music-player.xcodeproj` (note the scheme name), then
`xcodebuild -project youtube-music-player.xcodeproj -scheme <scheme> -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. Confirm the file is bundled:
`find ~/Library/Developer/Xcode/DerivedData -name 'fs-controls-util.js' -path '*youtube-music-player*' | head`
Expected: a path inside the built `.app`. If empty, the sync group didn't pick it up — add explicit pbxproj entries modeled on `butterchurn.min.js` (fileRef + PBXBuildFile + Resources phase entry) and rebuild.

- [ ] **Step 7: Commit**

```bash
git add youtube-music-player/Resources/visualizer/fs-controls-util.js harness/tests/fs-controls-util.spec.js youtube-music-player/YouTubeMusicWebView.swift
git commit -m "Add pure fs-controls-util module (idle controller + media helpers) with unit test"
```

---

## Task 2: Relocate windowed preset label to top

**Files:**
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js` (`showToast` ~790-815, `doLoadPreset` ~818-824)

**Interfaces:**
- Produces: `announcePreset(name)` — routes preset-name display. In this task it only handles the windowed toast (top-center). Task 4 extends it to update the fullscreen bar label.

- [ ] **Step 1: Add `announcePreset` and repoint the toast to the top.** Replace the `showToast` position and add the router. In `showToast`, change the positioning line:

```js
        // Windowed: sit at the TOP of the visualization (fullscreen routes to the bar label
        // instead — see announcePreset). left/transform center it horizontally.
        el.style.cssText =
            'position:absolute;top:24px;left:50%;transform:translateX(-50%);' +
            'font-family:sans-serif;font-size:13px;' +
            'padding:4px 12px;border-radius:12px;pointer-events:none;z-index:9999;' +
            'opacity:1;transition:opacity 1s ease;white-space:nowrap;';
```

Add, immediately after `showToast`:

```js
    // Route the preset name to the right surface. Fullscreen bar label is wired in Task 4;
    // until then (and always when windowed) fall back to the top toast.
    function announcePreset(name) {
        if (_barPresetLabel && isVizFullscreen()) { setBarPresetLabel(name); return; }
        showToast(name);
    }
```

- [ ] **Step 2: Add the `isVizFullscreen` helper** (used here and by Task 3/5). Place it near `addFullscreenControl`:

```js
    // True only when OUR canvas host is the fullscreen element (not YT's native video fs).
    function isVizFullscreen() {
        var fe = document.fullscreenElement || document.webkitFullscreenElement;
        return !!_canvasHost && fe === _canvasHost;
    }

    // Exit fullscreen with the WebKit-prefixed fallback (this feature already touches prefixed fs).
    function exitFs() {
        var fn = document.exitFullscreen || document.webkitExitFullscreen;
        if (fn) fn.call(document);
    }
```

Add the forward-declared bar globals near the other Task 10 `let`s (`_fsBtn` block) so this task compiles before Task 3 fills them in. **Use a reassignable `var` for `setBarPresetLabel` (not a `function` declaration) so Task 3 can replace it without a duplicate-declaration or delete step:**

```js
    let _barPresetLabel = null;              // the bar's preset-name span (assigned in Task 3)
    var setBarPresetLabel = function () {};  // no-op until Task 3 reassigns it
```

- [ ] **Step 3: Point `doLoadPreset` at the router.** In `doLoadPreset`, replace `showToast(name);` with `announcePreset(name);`.

- [ ] **Step 4: Build**

Run: `xcodebuild -project youtube-music-player.xcodeproj -scheme <scheme> -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual QA** — launch the built app, play a track, open the visualizer (windowed, now-playing page). On preset change (wait ~20s or press →), the preset name appears **top-center** and fades after ~2s. No bottom toast.

- [ ] **Step 6: Commit**

```bash
git add youtube-music-player/Resources/visualizer/visualizer.js
git commit -m "Move windowed visualizer preset label to top; add preset-name router"
```

---

## Task 3: Player bar DOM + styling + idle reveal/hide (visualizer adapter)

**Files:**
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js` (extend the Task 10 fullscreen module; hook `_fsChangeHandler` ~982-998, `removeFullscreenControl` ~1001-1012)

**Interfaces:**
- Consumes: `window.MilkVizCtl.createIdleController` (Task 1); `isVizFullscreen`, `_barPresetLabel`, `setBarPresetLabel` (Task 2).
- Produces: `_bar` (the bar element), `buildBar()`, `_idle` (the controller), `startIdle()/stopIdle()`, `applyVisualizerReveal(show)`. Bar controls are present but **not yet wired to playback** (Task 4).

- [ ] **Step 1: Inject bar CSS.** Add a `injectBarCss()` (called from `buildBar`). This styles the bar to match YT's native video bar — dark scrim, white glyphs, the thin red progress line — and defines the reveal/hide transition + reduced-motion. Selectors scoped to `#milkviz-bar`.

```js
    function injectBarCss() {
        if (document.getElementById('milkviz-bar-css')) return;
        const css = document.createElement('style');
        css.id = 'milkviz-bar-css';
        css.textContent = [
            // Scrim + bar container. Hidden by default (opacity 0 + slide down); .visible reveals.
            '#milkviz-bar{position:absolute;left:0;right:0;bottom:0;z-index:5;',
            'padding:28px 24px 16px;box-sizing:border-box;pointer-events:auto;',
            'background:linear-gradient(to top,rgba(0,0,0,.75) 0%,rgba(0,0,0,.55) 28%,rgba(0,0,0,0) 100%);',
            'opacity:0;transform:translateY(10px);visibility:hidden;',
            // Delay the visibility:hidden flip until AFTER the opacity/transform fade (0s @ .35s),
            // so the bar actually fades out over 350ms instead of snapping. Reveal flips
            // visibility immediately (0s @ 0s) so the fade-in is visible.
            'transition:opacity .35s ease, transform .35s ease, visibility 0s linear .35s;',
            'font-family:"Roboto",sans-serif;}',
            '#milkviz-bar.visible{opacity:1;transform:translateY(0);visibility:visible;',
            'transition:opacity .18s cubic-bezier(.16,1,.3,1), transform .18s cubic-bezier(.16,1,.3,1), visibility 0s;}',
            // Thin scrubbable progress line across the top of the bar.
            '#milkviz-seek{position:relative;height:3px;border-radius:2px;cursor:pointer;',
            'background:rgba(255,255,255,.3);margin-bottom:14px;}',
            '#milkviz-seek-played{position:absolute;left:0;top:0;bottom:0;width:0;border-radius:2px;',
            'background:#f00;}',
            '#milkviz-seek-knob{position:absolute;top:50%;width:12px;height:12px;border-radius:50%;',
            'background:#f00;transform:translate(-50%,-50%);left:0;opacity:0;transition:opacity .1s;}',
            '#milkviz-seek:hover #milkviz-seek-knob{opacity:1;}',
            // Control row.
            '#milkviz-row{display:flex;align-items:center;gap:16px;}',
            '#milkviz-bar button{border:0;background:transparent;padding:0;cursor:pointer;',
            'display:flex;align-items:center;justify-content:center;}',
            '#milkviz-bar button svg{width:24px;height:24px;stroke:#fff;fill:none;',
            'stroke-width:2;stroke-linecap:round;stroke-linejoin:round;}',
            '#milkviz-bar button:focus-visible{outline:2px solid #1A73E8;outline-offset:2px;}',
            // White-on-dark. LightThemeEngine stands down whenever any element is fullscreen
            // (LightThemeEngine.swift ~877: `fullscreenActive` gates `light`), and this bar is
            // fullscreen-only, so stylesheet !important suffices — no per-element inline fight
            // needed. (If QA shows any light bleed, escalate to excluding #milkviz-bar from the
            // engine's three restyle mechanisms — see the lightthemeengine-three-mechanisms note.)
            '#milkviz-bar,#milkviz-bar *{color:#fff !important;-webkit-text-fill-color:#fff !important;}',
            '#milkviz-time{font-size:13px;min-width:88px;white-space:nowrap;}',
            '#milkviz-meta{display:flex;align-items:center;gap:10px;min-width:0;flex:1;}',
            '#milkviz-thumb{width:40px;height:40px;border-radius:4px;object-fit:cover;flex:none;}',
            '#milkviz-title{font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}',
            // Volume: slider collapsed to 0 width, expands on hover/focus (YT-style).
            '#milkviz-vol-wrap{display:flex;align-items:center;gap:6px;flex:none;}',
            '#milkviz-vol-slider{width:0;opacity:0;height:4px;accent-color:#fff;cursor:pointer;',
            'transition:width .18s ease, opacity .18s ease;}',
            '#milkviz-vol-wrap:hover #milkviz-vol-slider,#milkviz-vol-slider:focus-visible{width:72px;opacity:1;}',
            '#milkviz-preset{display:flex;align-items:center;gap:6px;flex:none;}',
            '#milkviz-preset-name{font-size:12px;max-width:160px;overflow:hidden;text-overflow:ellipsis;',
            'white-space:nowrap;opacity:.85;}',
            // Reduced motion: kill duration AND the visibility delay (else the bar strands
            // visible for 350ms), drop the slide. Hide behavior itself is preserved.
            '@media (prefers-reduced-motion: reduce){#milkviz-bar{transition-duration:.01ms;transition-delay:0s;transform:none;}',
            '#milkviz-bar.visible{transition-duration:.01ms;transition-delay:0s;transform:none;}}',
        ].join('');
        document.head.appendChild(css);
    }
```

- [ ] **Step 2: Add SVG glyph constants** (match YT's stroke style; reuse the existing `FS_ICON_SVG` shape language). Place near `FS_ICON_SVG`:

```js
    const ICON = {
        prev: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 5v14M20 5l-10 7 10 7z"/></svg>',
        next: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M18 5v14M4 5l10 7-10 7z"/></svg>',
        play: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 4l14 8-14 8z" fill="#fff" stroke="none"/></svg>',
        pause: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 4v16M17 4v16"/></svg>',
        vol: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9v6h4l5 4V5L8 9zM16 8a5 5 0 010 8"/></svg>',
        volMute: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9v6h4l5 4V5L8 9zM17 9l4 6M21 9l-4 6"/></svg>',
        presetPrev: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 6l-6 6 6 6"/></svg>',
        presetNext: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l6 6-6 6"/></svg>',
        exitFs: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 4v5H4M20 9h-5V4M4 15h5v5M15 20v-5h5"/></svg>',
    };
```

- [ ] **Step 3: Build the bar DOM.** Add `buildBar()` — creates `#milkviz-bar` as a **sibling of the canvas** inside `_canvasHost`. Buttons carry `aria-label`s; wiring is added in Task 4 (here they are inert). Also sets `_barPresetLabel` and the real `setBarPresetLabel`.

```js
    let _bar = null, _barPlayBtn = null, _barVolBtn = null, _barVolSlider = null,
        _barPlayed = null, _barKnob = null, _barTime = null, _barThumb = null, _barTitle = null;
    let _barVolSliding = false;   // true while dragging the volume slider (don't fight its value)

    // Task 4 fills these in; no-op stubs so Task 3 runs standalone (REASSIGNED, not redeclared).
    var resolveVideo = function () { return null; };
    var bindVideo = function () {};
    var unbindVideo = function () {};
    var updateBarMeta = function () {};

    function mkBtn(id, label, svg) {
        const b = document.createElement('button');
        b.id = id; b.type = 'button';
        b.setAttribute('aria-label', label); b.title = label;
        b.innerHTML = svg;
        return b;
    }

    function buildBar() {
        if (_bar || !_canvasHost) return;
        injectBarCss();
        const bar = document.createElement('div');
        bar.id = 'milkviz-bar';
        bar.setAttribute('role', 'group');
        bar.setAttribute('aria-label', 'Playback controls');

        const seek = document.createElement('div');
        seek.id = 'milkviz-seek';
        seek.setAttribute('role', 'slider'); seek.setAttribute('aria-label', 'Seek');
        seek.innerHTML = '<div id="milkviz-seek-played"></div><div id="milkviz-seek-knob"></div>';

        const row = document.createElement('div'); row.id = 'milkviz-row';
        const prev = mkBtn('milkviz-prev', 'Previous', ICON.prev);
        const play = mkBtn('milkviz-play', 'Play', ICON.play);
        const next = mkBtn('milkviz-next', 'Next', ICON.next);
        const time = document.createElement('div'); time.id = 'milkviz-time'; time.textContent = '0:00 / 0:00';

        const meta = document.createElement('div'); meta.id = 'milkviz-meta';
        const thumb = document.createElement('img'); thumb.id = 'milkviz-thumb'; thumb.alt = '';
        const title = document.createElement('div'); title.id = 'milkviz-title';
        meta.appendChild(thumb); meta.appendChild(title);

        // Volume: icon (mute toggle) + slider that expands on hover, matching YT's video bar.
        const volWrap = document.createElement('div'); volWrap.id = 'milkviz-vol-wrap';
        const vol = mkBtn('milkviz-vol', 'Mute', ICON.vol);
        const volSlider = document.createElement('input');
        volSlider.id = 'milkviz-vol-slider'; volSlider.type = 'range';
        volSlider.min = '0'; volSlider.max = '1'; volSlider.step = '0.01'; volSlider.value = '1';
        volSlider.setAttribute('aria-label', 'Volume');
        volWrap.appendChild(vol); volWrap.appendChild(volSlider);

        const preset = document.createElement('div'); preset.id = 'milkviz-preset';
        const pPrev = mkBtn('milkviz-preset-prev', 'Previous preset', ICON.presetPrev);
        const pName = document.createElement('div'); pName.id = 'milkviz-preset-name';
        pName.setAttribute('aria-live', 'polite');
        const pNext = mkBtn('milkviz-preset-next', 'Next preset', ICON.presetNext);
        preset.appendChild(pPrev); preset.appendChild(pName); preset.appendChild(pNext);

        const exit = mkBtn('milkviz-exit', 'Exit fullscreen', ICON.exitFs);

        row.appendChild(prev); row.appendChild(play); row.appendChild(next);
        row.appendChild(time); row.appendChild(meta); row.appendChild(volWrap);
        row.appendChild(preset); row.appendChild(exit);
        bar.appendChild(seek); bar.appendChild(row);
        _canvasHost.appendChild(bar);   // sibling of the canvas; NOT inside it

        _bar = bar; _barPlayBtn = play; _barVolBtn = vol; _barVolSlider = volSlider;
        _barPlayed = bar.querySelector('#milkviz-seek-played');
        _barKnob = bar.querySelector('#milkviz-seek-knob');
        _barTime = time; _barThumb = thumb; _barTitle = title;
        _barPresetLabel = pName;
    }

    // Real implementation — REASSIGN the Task 2 var (do not redeclare; `_barPresetLabel`
    // and `var setBarPresetLabel` already exist from Task 2).
    setBarPresetLabel = function (name) {
        if (!_barPresetLabel) return;
        _barPresetLabel.textContent = name || '';
        _barPresetLabel.title = name || '';
    };
```

Do NOT delete or redeclare the Task-2 `let _barPresetLabel = null;` / `var setBarPresetLabel` lines — Task 3 only assigns `_barPresetLabel = pName` (inside `buildBar`) and reassigns `setBarPresetLabel`. Keeping the single Task-2 declarations avoids the strict-mode `ReferenceError`.

- [ ] **Step 4: Wire the idle controller + activity listeners.** Add the visualizer adapter and the shared listeners. `startIdle()` builds the controller and binds document listeners; `stopIdle()` tears everything down.

```js
    let _idle = null, _idleListeners = null;

    function applyVisualizerReveal(show) {
        if (!_bar) return;
        _bar.classList.toggle('visible', show);
        if (_canvasHost) _canvasHost.style.cursor = show ? 'auto' : 'none';
    }

    // Peek zone: bottom 15% of the host counts as activity even before reaching the bar.
    function inPeekZone(e) {
        if (!_canvasHost) return false;
        const r = _canvasHost.getBoundingClientRect();
        return e.clientY >= r.bottom - r.height * 0.15;
    }

    function startIdle(onShow, onHide) {
        stopIdle();
        _idle = window.MilkVizCtl.createIdleController({ onShow: onShow, onHide: onHide });

        const onMove = function (e) {
            if (inPeekZone(e)) _idle.reveal(); else _idle.activity(e.clientX, e.clientY);
        };
        const onDown = function () { _idle.reveal(); };
        const onFocus = function () { _idle.reveal(); };
        const onKey = function (e) {
            if (['ArrowLeft','ArrowRight',' ','k','m','f','Escape'].indexOf(e.key) !== -1) _idle.reveal();
        };
        const onScrubEnd = function () { _idle.setLock('scrub', false); };

        document.addEventListener('mousemove', onMove);
        document.addEventListener('pointerdown', onDown);
        document.addEventListener('focusin', onFocus);
        document.addEventListener('keydown', onKey);
        window.addEventListener('pointerup', onScrubEnd);
        window.addEventListener('pointercancel', onScrubEnd);
        window.addEventListener('lostpointercapture', onScrubEnd);
        window.addEventListener('blur', onScrubEnd);
        _idleListeners = { onMove, onDown, onFocus, onKey, onScrubEnd };
        _idle.reveal();   // controls visible on entry, then auto-hide after the idle timeout
    }

    function stopIdle() {
        if (_idleListeners) {
            const l = _idleListeners;
            document.removeEventListener('mousemove', l.onMove);
            document.removeEventListener('pointerdown', l.onDown);
            document.removeEventListener('focusin', l.onFocus);
            document.removeEventListener('keydown', l.onKey);
            window.removeEventListener('pointerup', l.onScrubEnd);
            window.removeEventListener('pointercancel', l.onScrubEnd);
            window.removeEventListener('lostpointercapture', l.onScrubEnd);
            window.removeEventListener('blur', l.onScrubEnd);
            _idleListeners = null;
        }
        if (_idle) { _idle.destroy(); _idle = null; }
        if (_canvasHost) _canvasHost.style.cursor = 'auto';
    }
```

- [ ] **Step 5: Bar hover + focus locks.** In `buildBar`, before `_canvasHost.appendChild(bar)`, add:

```js
        bar.addEventListener('pointerenter', function () { if (_idle) _idle.setLock('hover', true); });
        bar.addEventListener('pointerleave', function () { if (_idle) _idle.setLock('hover', false); });
        bar.addEventListener('focusin', function () { if (_idle) { _idle.reveal(); _idle.setLock('focus', true); } });
        bar.addEventListener('focusout', function (e) {
            if (_idle && !bar.contains(e.relatedTarget)) _idle.setLock('focus', false);
        });
```

- [ ] **Step 6a: Keep `_fsChangeHandler` rendering-only.** `_fsChangeHandler` (defined in `addFullscreenControl`, bound on `_canvasHost`'s fullscreen events, only while the visualizer is active) must NOT touch the idle controller or the bar — a single global handler (Step 6b) owns those, so ownership isn't split. Replace its body so it only does canvas rendering + the top-right FS button visibility:

```js
        _fsChangeHandler = function () {
            const inFs = isVizFullscreen();
            if (_canvasHost) {
                _canvasHost.style.padding = inFs ? '0' : '24px';
                _canvasHost.style.background = inFs ? '#000' : pageBgColor();
            }
            applySize();
            if (_fsBtn) {
                // Top-right FS button hides in fullscreen (exit lives in the bar); shows when windowed.
                _fsBtn.style.display = inFs ? 'none' : '';
                _fsBtn.title = inFs ? 'Exit fullscreen' : 'Enter fullscreen';
                _fsBtn.setAttribute('aria-label', _fsBtn.title);
            }
        };
```

- [ ] **Step 6b: Add the single global fullscreen handler** (sole owner of adapter selection + bar + idle). Bound ONCE at boot regardless of whether the visualizer is active, so it also covers native YT video fullscreen (Task 5 fills the `video` branch). Place near `startSegObserver`:

```js
    let _activeAdapter = null;   // 'viz' | 'video' | null — exactly one idle owner at a time
    let _globalFsBound = false;

    function onGlobalFsChange() {
        const fe = document.fullscreenElement || document.webkitFullscreenElement;
        let want = !fe ? null : (isVizFullscreen() ? 'viz' : 'video');
        // Guard the teardown race: removeFullscreenControl() may exit fullscreen (async) and null
        // _activeAdapter while _canvasHost still momentarily exists. If the visualizer is no longer
        // active, never (re)build the viz adapter on a late fullscreenchange.
        if (want === 'viz' && !_active) want = null;
        if (want === _activeAdapter) return;   // idempotent: ignore no-op re-fires

        // Tear down whatever adapter was active.
        if (_activeAdapter === 'viz') {
            stopIdle();
            unbindVideo();                                   // no-op until Task 4 defines it
            if (_bar) { _bar.remove(); _bar = null; _barPresetLabel = null; }
        } else if (_activeAdapter === 'video') {
            stopIdle();
            document.documentElement.classList.remove('milkviz-idle');
        }
        _activeAdapter = want;

        // Start the newly-selected adapter.
        if (want === 'viz') {
            buildBar();
            startIdle(function () { applyVisualizerReveal(true); },
                      function () { applyVisualizerReveal(false); });
            bindVideo(resolveVideo());                       // no-ops until Task 4 defines them
            updateBarMeta();
            if (_presetNames.length) setBarPresetLabel(_presetNames[_presetIdx]);
        }
        // want === 'video' branch is added in Task 5.
    }

    function bindGlobalFs() {
        if (_globalFsBound) return;
        _globalFsBound = true;
        document.addEventListener('fullscreenchange', onGlobalFsChange);
        document.addEventListener('webkitfullscreenchange', onGlobalFsChange);
    }
```

**Forward-reference note:** `unbindVideo`, `bindVideo`, `resolveVideo`, `updateBarMeta` are the no-op `var` stubs declared in the Task 3 Step 3 globals block; Task 4 REASSIGNS them (`resolveVideo = function(){...}`, not a `function` declaration) so there's no duplicate declaration. This lets Task 3 build and run standalone (bar with no live playback wiring).

- [ ] **Step 6c: Bind the global handler at boot.** In `startSegObserver()`, after the `music.youtube.com` host check, add `bindGlobalFs();`.

- [ ] **Step 7: Wire exit-fullscreen button.** In `buildBar`, after creating `exit`:

```js
        exit.addEventListener('click', function (e) { e.stopPropagation(); exitFs(); });
```

- [ ] **Step 8: Teardown on visualizer off.** `removeFullscreenControl` runs when the visualizer is deactivated (possibly while still fullscreen). Add before the `_fsBtn` removal (Task 4 Step 6 adds `unbindVideo();` here too):

```js
        stopIdle();
        if (_bar) { _bar.remove(); _bar = null; _barPresetLabel = null; }
        document.documentElement.classList.remove('milkviz-idle');   // belt-and-braces (video adapter)
        _activeAdapter = null;   // reset the global handler's state so a later fs re-fires cleanly
```

- [ ] **Step 9: Build**

Run: `xcodebuild -project youtube-music-player.xcodeproj -scheme <scheme> -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Manual QA** — play a track, open visualizer, enter fullscreen (top-right button). Observe: bar slides up + fades in, then **auto-hides after ~2.5s** with the cursor. Moving the mouse reveals it (snappy); moving into the bottom 15% reveals it; parking the cursor **over the bar** keeps it up; tabbing focuses controls and keeps it up. Preset changes update the bar's preset name (truncated). Exit button leaves fullscreen; the top-right FS button reappears windowed. Enter/exit fullscreen 3× — no stuck bar, no doubled reveal.

- [ ] **Step 11: Commit**

```bash
git add youtube-music-player/Resources/visualizer/visualizer.js
git commit -m "Add fullscreen visualizer control bar with idle auto-hide (visualizer adapter)"
```

---

## Task 4: Wire transport, seek, volume, and metadata

**Files:**
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js` (bar wiring; extend `buildBar` teardown)

**Interfaces:**
- Consumes: `MilkVizCtl.pickActiveVideo/formatTime/clampSeek` (Task 1); bar elements from Task 3; existing `doLoadPreset`, `_checkTrack` track poll.
- Produces: `resolveVideo()`, `bindVideo(v)`, `unbindVideo()`, `updateBarTransport()`, `updateBarMeta()` — bar reflects real playback and drives YT's controls.

- [ ] **Step 1: Active-video resolution + binding.** **REASSIGN** the Task 3 Step 6b stubs (`resolveVideo`, `bindVideo`, `unbindVideo` already exist as `var` no-op stubs — assign, do not redeclare). Add:

```js
    let _barVideo = null, _barVideoEvents = null;

    resolveVideo = function () {
        return window.MilkVizCtl.pickActiveVideo(document.querySelectorAll('video'));
    };

    bindVideo = function (v) {
        if (v === _barVideo) return;
        unbindVideo();
        _barVideo = v;
        if (!v) return;
        const onTime = function () { updateBarTransport(); };
        const onState = function () { updateBarTransport(); };
        v.addEventListener('timeupdate', onTime);
        v.addEventListener('play', onState);
        v.addEventListener('pause', onState);
        v.addEventListener('volumechange', onState);
        _barVideoEvents = { onTime, onState };
        updateBarTransport();
    };

    unbindVideo = function () {
        if (_barVideo && _barVideoEvents) {
            _barVideo.removeEventListener('timeupdate', _barVideoEvents.onTime);
            _barVideo.removeEventListener('play', _barVideoEvents.onState);
            _barVideo.removeEventListener('pause', _barVideoEvents.onState);
            _barVideo.removeEventListener('volumechange', _barVideoEvents.onState);
        }
        _barVideo = null; _barVideoEvents = null;
    };
```

- [ ] **Step 2: Transport + meta updaters.** Add:

```js
    // New in Task 4 (not stubbed) — plain declaration is fine.
    function updateBarTransport() {
        if (!_bar) return;
        const v = _barVideo;
        const fmt = window.MilkVizCtl.formatTime;
        if (v && isFinite(v.duration) && v.duration > 0) {
            const pct = Math.max(0, Math.min(1, v.currentTime / v.duration)) * 100;
            _barPlayed.style.width = pct + '%';
            _barKnob.style.left = pct + '%';
            _barTime.textContent = fmt(v.currentTime) + ' / ' + fmt(v.duration);
        } else {
            _barPlayed.style.width = '0%'; _barKnob.style.left = '0%';
            _barTime.textContent = '0:00 / 0:00';
        }
        const paused = !v || v.paused;
        _barPlayBtn.innerHTML = paused ? ICON.play : ICON.pause;
        _barPlayBtn.setAttribute('aria-label', paused ? 'Play' : 'Pause');
        _barPlayBtn.setAttribute('aria-pressed', paused ? 'false' : 'true');
        _barPlayBtn.title = paused ? 'Play' : 'Pause';
        const muted = !!(v && v.muted);
        _barVolBtn.innerHTML = muted ? ICON.volMute : ICON.vol;
        _barVolBtn.setAttribute('aria-label', muted ? 'Unmute' : 'Mute');
        _barVolBtn.setAttribute('aria-pressed', muted ? 'true' : 'false');
        if (_barVolSlider && v && !_barVolSliding) _barVolSlider.value = String(v.muted ? 0 : v.volume);
    }

    // REASSIGN the Task 3 Step 6b stub (do not redeclare).
    updateBarMeta = function () {
        if (!_bar) return;
        const meta = navigator.mediaSession && navigator.mediaSession.metadata;
        const title = meta && meta.title ? meta.title : '';
        const artist = meta && meta.artist ? meta.artist : '';
        _barTitle.textContent = title ? (artist ? (title + ' — ' + artist) : title) : '';
        const art = meta && meta.artwork && meta.artwork.length ? meta.artwork[meta.artwork.length - 1].src : '';
        if (art) { _barThumb.src = art; _barThumb.style.display = ''; }
        else { _barThumb.removeAttribute('src'); _barThumb.style.display = 'none'; }
    };
```

- [ ] **Step 3: Proxy YT transport buttons.** Add a helper that finds+clicks YT's real player-bar buttons, and hides prev/next if absent:

```js
    // Best-effort: YT Music's player-bar transport controls. Selectors are confirmed in QA
    // (headless DOM inspection isn't possible — see the file's segment-detection note).
    function ytBtn(kind) {
        const bar = document.querySelector('ytmusic-player-bar');
        if (!bar) return null;
        const map = {
            play: '#play-pause-button',
            prev: 'tp-yt-paper-icon-button.previous-button, .previous-button',
            next: 'tp-yt-paper-icon-button.next-button, .next-button',
        };
        return bar.querySelector(map[kind]);
    }

    function proxyClick(kind, videoFallback) {
        const b = ytBtn(kind);
        if (b) { b.click(); return true; }
        if (videoFallback) videoFallback();
        return false;
    }
```

- [ ] **Step 4: Attach control handlers.** In `buildBar`, after the elements exist (before/after the exit handler), wire the buttons, seek, and volume. Add:

```js
        prev.addEventListener('click', function (e) { e.stopPropagation(); proxyClick('prev'); });
        next.addEventListener('click', function (e) { e.stopPropagation(); proxyClick('next'); });
        play.addEventListener('click', function (e) {
            e.stopPropagation();
            proxyClick('play', function () {
                const v = _barVideo || resolveVideo();
                if (v) { v.paused ? v.play() : v.pause(); }
            });
        });
        vol.addEventListener('click', function (e) {
            e.stopPropagation();
            const v = _barVideo || resolveVideo();
            if (v) { v.muted = !v.muted; }
        });
        volSlider.addEventListener('pointerdown', function () { _barVolSliding = true; });
        volSlider.addEventListener('input', function (e) {
            e.stopPropagation();
            const v = _barVideo || resolveVideo();
            if (!v) return;
            const val = parseFloat(volSlider.value);
            v.volume = val; v.muted = val === 0;
        });
        const volDone = function () { _barVolSliding = false; };
        volSlider.addEventListener('pointerup', volDone);
        volSlider.addEventListener('pointercancel', volDone);
        volSlider.addEventListener('blur', volDone);
        pPrev.addEventListener('click', function (e) { e.stopPropagation(); doLoadPreset(_presetIdx - 1, 2.7); scheduleCycle(); });
        pNext.addEventListener('click', function (e) { e.stopPropagation(); doLoadPreset(_presetIdx + 1, 2.7); scheduleCycle(); });

        // Hide prev/next if YT's buttons aren't present (never leave a dead control).
        if (!ytBtn('prev')) prev.style.display = 'none';
        if (!ytBtn('next')) next.style.display = 'none';

        // Seek: click-to-seek and drag-to-scrub via clampSeek on the active video.
        const seekTo = function (clientX) {
            const v = _barVideo || resolveVideo();
            if (!v) return;
            const r = seek.getBoundingClientRect();
            const frac = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
            const t = window.MilkVizCtl.clampSeek(frac * v.duration, v.duration);
            if (t !== null) { v.currentTime = t; updateBarTransport(); }
        };
        seek.addEventListener('pointerdown', function (e) {
            e.stopPropagation();
            if (_idle) _idle.setLock('scrub', true);
            seekTo(e.clientX);
            const move = function (ev) { seekTo(ev.clientX); };
            const up = function () {
                document.removeEventListener('pointermove', move);
                document.removeEventListener('pointerup', up);
                document.removeEventListener('pointercancel', up);
                if (_idle) _idle.setLock('scrub', false);
            };
            document.addEventListener('pointermove', move);
            document.addEventListener('pointerup', up);
            document.addEventListener('pointercancel', up);
        });
```

- [ ] **Step 5: Refresh the bar on track change.** The bar-open refresh already lives in `onGlobalFsChange` (Task 3 Step 6b) — now that `bindVideo`/`resolveVideo`/`updateBarMeta` are real, that path works. Add a track-change refresh so title/thumb/active-video stay current: in `_checkTrack` (preset manager), after `doLoadPreset(...)`, add:

```js
            if (isVizFullscreen()) { bindVideo(resolveVideo()); updateBarMeta(); }
```

- [ ] **Step 6: Unbind on teardown.** `onGlobalFsChange`'s viz-teardown branch already calls `unbindVideo()` (Task 3 Step 6b). Also add `unbindVideo();` to `removeFullscreenControl` (visualizer turned off entirely, which may happen while still in fullscreen), next to the `stopIdle();`/`_bar` removal added in Task 3 Step 8.

- [ ] **Step 7: Build**

Run: `xcodebuild -project youtube-music-player.xcodeproj -scheme <scheme> -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Manual QA** — in visualizer fullscreen: play/pause toggles and its icon flips; prev/next change tracks; the seek line advances and click/drag seeks (bar stays visible during drag, even if released outside the bar); time reads `M:SS / M:SS`; volume button mutes/unmutes; thumbnail+title reflect the track and update on track change; long preset names truncate with ellipsis (full name on hover). Confirm bar button clicks are NOT swallowed (no preset-skip firing when you click a control).

- [ ] **Step 9: Commit**

```bash
git add youtube-music-player/Resources/visualizer/visualizer.js
git commit -m "Wire fullscreen bar transport, seek, volume, and metadata to YT playback"
```

---

## Task 5: Video adapter — idle-hide over native YT video fullscreen

**Files:**
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js`

**Interfaces:**
- Consumes: `onGlobalFsChange` + `_activeAdapter` (Task 3 Step 6b), `startIdle/stopIdle`, `applyVideoReveal`.
- Produces: `injectVideoIdleCss()`, `videoFsChrome()`, `applyVideoReveal(show)`, and the `want === 'video'` branch of `onGlobalFsChange`.

- [ ] **Step 0 — QA SPIKE (do this first; it gates the rest).** The exact YT video-fullscreen chrome element is NOT assumed. In a DEBUG build, play a music video, fullscreen it, and inspect via Safari Develop → the WKWebView. Determine: (a) which element is the visible control bar in native video fullscreen, (b) whether it's in a shadow root (a stylesheet in `<head>` can't reach shadow-DOM). Record the winning selector. If it's shadow-encapsulated, the inline-style path in Step 2 (which sets style on the resolved element directly) still works **as long as `videoFsChrome()` can resolve it** — extend `videoFsChrome()`'s selector list or add a shadow-root traversal. **Do not commit Task 5 until the bar actually hides in QA (Step 6).**

- [ ] **Step 1: Inject the cursor-hide CSS.** The bar-hide is done via inline style (Step 2, robust to YT inline `!important` and shadow DOM); the class only drives the cursor. Add:

```js
    function injectVideoIdleCss() {
        if (document.getElementById('milkviz-video-idle-css')) return;
        const css = document.createElement('style');
        css.id = 'milkviz-video-idle-css';
        css.textContent = 'html.milkviz-idle, html.milkviz-idle *{cursor:none !important;}';
        document.head.appendChild(css);
    }
```

- [ ] **Step 2: Chrome resolver + reveal/hide.** `applyVideoReveal` toggles the cursor class AND inline-hides the resolved chrome (inline `!important` beats YT's own inline styles). Add:

```js
    // YT's native video-fullscreen chrome. Selector list confirmed/extended by the Step 0 spike.
    function videoFsChrome() {
        const sels = ['ytmusic-player-bar', '.ytp-chrome-bottom', '.ytmusic-player-bar'];
        for (let i = 0; i < sels.length; i++) {
            const el = document.querySelector(sels[i]);
            if (el) return el;
        }
        return null;
    }

    function applyVideoReveal(show) {
        document.documentElement.classList.toggle('milkviz-idle', !show);   // cursor:none when hidden
        const el = videoFsChrome();
        if (!el) return;
        if (show) {
            // Restore: clear every inline override we set (leave YT's own styles intact).
            el.style.removeProperty('opacity');
            el.style.removeProperty('visibility');
            el.style.removeProperty('pointer-events');
            el.style.removeProperty('transition');
        } else {
            el.style.setProperty('opacity', '0', 'important');
            el.style.setProperty('pointer-events', 'none', 'important');
            // Delay the visibility flip until after the opacity fade (same trick as the viz bar).
            el.style.setProperty('transition', 'opacity .35s ease, visibility 0s linear .35s', 'important');
            el.style.setProperty('visibility', 'hidden', 'important');
        }
    }
```

- [ ] **Step 3: Fill the `video` branch of the global handler.** `onGlobalFsChange` (Task 3 Step 6b) already selects `_activeAdapter` and tears down the previous adapter; add the video START branch. In `onGlobalFsChange`, replace the trailing comment `// want === 'video' branch is added in Task 5.` with:

```js
        else if (want === 'video') {
            injectVideoIdleCss();
            startIdle(function () { applyVideoReveal(true); },
                      function () { applyVideoReveal(false); });
        }
```

No new listener is added — the single global handler owns both adapters, so they can't fight over the controller (visualizer teardown already ran before this branch, since `want !== _activeAdapter`). The video-teardown branch (Task 3 Step 6b) already calls `stopIdle()` + removes `.milkviz-idle`; also clear the inline hide there — update that branch to:

```js
        } else if (_activeAdapter === 'video') {
            stopIdle();
            applyVideoReveal(true);   // clears the inline hide + the cursor class
        }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project youtube-music-player.xcodeproj -scheme <scheme> -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual QA** — play a real music VIDEO (Song/Video toggle → Video), fullscreen it (YT's own fullscreen). After ~2.5s idle the YT bar fades and cursor hides; mouse move reveals it. Exit fullscreen → YT bar returns to normal, `.milkviz-idle` gone and the chrome's inline opacity cleared (check `document.documentElement.className` and the resolved bar's `style`). Then enter the VISUALIZER fullscreen and confirm `.milkviz-idle` is NOT applied there (visualizer uses its own bar). If the YT bar didn't hide, `videoFsChrome()` didn't resolve the right element — extend its selector list per the Step 0 spike (or add shadow-root traversal).

- [ ] **Step 6: Commit**

```bash
git add youtube-music-player/Resources/visualizer/visualizer.js
git commit -m "Apply idle auto-hide to native YT video fullscreen (video adapter)"
```

---

## Task 6: Accessibility + leak/lifecycle hardening pass

**Files:**
- Modify: `youtube-music-player/Resources/visualizer/visualizer.js`

- [ ] **Step 1: Focus-visibility while hidden.** When the bar is hidden (`opacity:0; visibility:hidden`), its controls are correctly non-focusable — but `focusin` must still reveal it if focus is programmatically moved in. Confirm the CSS uses `visibility:hidden` (Task 3 does) so hidden controls are removed from the tab order, and that the bar's `focusin` handler (Task 3 Step 5) reveals on focus. Add a keydown shortcut so `Escape` in visualizer fullscreen exits (matches native): in the `onKey` handler (Task 3 Step 4), extend:

```js
        const onKey = function (e) {
            if (e.key === 'Escape' && isVizFullscreen()) { exitFs(); return; }
            if (['ArrowLeft','ArrowRight',' ','k','m','f','Escape'].indexOf(e.key) !== -1) _idle.reveal();
        };
```

- [ ] **Step 2: Verify the reduced-motion visibility choreography.** Task 3 Step 1's base rule delays `visibility:hidden` by `.35s` so the fade is visible; the reduced-motion media query (Task 3 Step 1) must therefore also zero `transition-delay` (it does) — otherwise the bar strands visible for 350ms. Confirm the media query includes `transition-delay:0s` on both `#milkviz-bar` and `#milkviz-bar.visible`. Test with Reduce Motion enabled in System Settings → Accessibility → Display: the bar snaps in/out with no slide and never sticks.

- [ ] **Step 3: Leak audit.** Enter/exit visualizer fullscreen 5×, enter/exit native video fullscreen 5×, toggle the visualizer off/on 3×. After each cycle confirm (DEBUG inspector console): exactly one (or zero) `mousemove` listener churns via `stopIdle` (add a temporary `console.count` if needed, remove before commit); no `#milkviz-bar` remains after exit; `.milkviz-idle` is absent after exit; `document.querySelectorAll('#milkviz-bar').length` is 0 or 1, never more.

- [ ] **Step 4: Run the unit test + build (regression)**

Run: `cd harness && source ~/.nvm/nvm.sh && nvm use && npx playwright test tests/fs-controls-util.spec.js`
Expected: PASS.
Run: `xcodebuild -project youtube-music-player.xcodeproj -scheme <scheme> -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Full manual QA checklist (spec §10).** Verify every item: repeated fullscreen enter/exit leaves no leaked listeners/bars; native video fullscreen selector hides+restores YT's bar; bar clicks reach controls (not eaten by `_onDocClickCapture`); scrub started in-bar and released outside releases the lock; `.milkviz-idle` gone after exit; preset label truncates; enter-fullscreen still works via the native bridge; `prefers-reduced-motion` snaps; keyboard focus reveals and holds the bar.

- [ ] **Step 6: Commit**

```bash
git add youtube-music-player/Resources/visualizer/visualizer.js
git commit -m "Harden fullscreen bar accessibility, reduced-motion, and listener lifecycle"
```

---

## Self-Review

**Spec coverage:**
- §3 control set (transport + presets) → Tasks 3-4. Bar fullscreen-only → Task 3 Step 6. Windowed preset label to top → Task 2. Preset folded into bar → Task 4 Step 5. Match YT styling → Task 3 Steps 1-2. Idle both surfaces → Tasks 3 (visualizer) + 5 (video). Timeout/threshold/grace → Task 1 defaults. Transport wiring (proxy + video) → Task 4. No pbxproj / one Swift line → Task 1 Steps 5-6.
- §4.1 idle controller interface (activity/reveal/setLock/destroy, locks, grace) → Task 1. §4.2 adapters + fullscreen detection + webkit prefix + `<html>` root + selector spike → Tasks 3, 5. §4.3 bar structure sibling-of-canvas, active-video resolution, duration guards, buffering omitted, metadata fallbacks → Tasks 3-4. §5 scrim/motion/peek → Task 3. §6 a11y/reduced-motion → Task 6. §7 theme survival → Task 3 Step 1 + Task 5 Step 1. §8 lifecycle/leaks → Tasks 3-6. §9 preset routing → Tasks 2, 4. §10 tests → Task 1 (auto) + manual checklists.

**Type consistency:** `createIdleController` returns `{activity, reveal, setLock, destroy, isVisible}` — used consistently in Tasks 3-5. `pickActiveVideo/formatTime/clampSeek` signatures match Task 1 usages. `_barPresetLabel` is declared once (Task 2) and only assigned thereafter; `setBarPresetLabel`, `resolveVideo`, `bindVideo`, `unbindVideo`, `updateBarMeta` are declared once as reassignable `var` stubs (Task 2/Task 3 globals) and REASSIGNED in Task 3/Task 4 — no deletes, no redeclarations, no duplicate-declaration errors.

**Placeholder scan:** none — every step has concrete code or exact commands. `<scheme>` is intentionally resolved by `xcodebuild -list` in Task 1 Step 6 (real projects vary); note it once and reuse.
