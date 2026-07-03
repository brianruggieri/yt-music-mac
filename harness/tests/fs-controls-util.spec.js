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
