import { test, expect } from '@playwright/test';
import { loadEngineScript } from '../lib/engine.js';

const ENGINE = loadEngineScript();

// A crossfade on the dark<->light toggle (View Transitions API). We drive the mode
// through the engine's own `__ytmSetSystemDark` entry point (the animated path,
// same as a real macOS appearance change) on a minimal local page — no dependence
// on live YT. The durable version of the manual spike that green-lit this feature.
const PAGE =
  'data:text/html,' +
  encodeURIComponent(
    '<!doctype html><html><head><style>' +
      'html[data-ytm-mode="dark"]{background:#0b0b0b}html[data-ytm-mode="light"]{background:#f3f3f3}' +
      // Mirror the app's SCOPED rule: the tuned duration applies only under the engine's marker class.
      'html.ytm-theme-vt::view-transition-old(root),html.ytm-theme-vt::view-transition-new(root){animation-duration:.4s}' +
      '</style></head><body>theme</body></html>'
  );

test.beforeEach(async ({ page }) => {
  await page.addInitScript({ content: ENGINE });
});

// Land in dark and wait for it to settle (a light-booted project crossfades on the
// way in — don't start sampling until that has finished).
async function seedDark(page) {
  await page.evaluate(() => window.__ytmSetSystemDark(true));
  await page.waitForFunction(
    () => document.documentElement.getAttribute('data-ytm-mode') === 'dark',
    null,
    { timeout: 5000 }
  );
  await page.waitForTimeout(500);
}

// Toggle dark -> light and sample the old-snapshot opacity across the animation
// window. A real crossfade ramps ::view-transition-old(root) opacity 1 -> 0.
async function sampleToLight(page) {
  return page.evaluate(async () => {
    const de = document.documentElement;
    const samples = [];
    const durations = [];
    let sawClass = false;
    window.__ytmSetSystemDark(false);
    for (let i = 0; i < 12; i++) {
      await new Promise((r) => requestAnimationFrame(r));
      if (de.classList.contains('ytm-theme-vt')) sawClass = true;
      const cs = getComputedStyle(de, '::view-transition-old(root)');
      if (cs.opacity !== '' && cs.opacity != null) samples.push(Number(cs.opacity));
      if (cs.animationDuration) durations.push(cs.animationDuration);
    }
    await new Promise((r) => setTimeout(r, 500));
    return {
      finalMode: de.getAttribute('data-ytm-mode'),
      samples: samples.filter((n) => !Number.isNaN(n)),
      durations,
      sawClass,
      classCleared: !de.classList.contains('ytm-theme-vt'),
    };
  });
}

test('theme toggle crossfades via View Transitions', async ({ page }) => {
  await page.goto(PAGE, { waitUntil: 'commit' });
  // The API must be present in the app's WebKit (it is on Safari/WebKit 18+).
  expect(await page.evaluate(() => typeof document.startViewTransition === 'function')).toBe(true);

  await seedDark(page);
  const { finalMode, samples, durations, sawClass, classCleared } = await sampleToLight(page);
  expect(finalMode).toBe('light');

  // A real crossfade drives the old snapshot's opacity well below 1 as it fades out.
  // (An instant snap leaves the pseudo pinned at ~1 the whole window.)
  expect(samples.length).toBeGreaterThanOrEqual(3);
  expect(Math.min(...samples)).toBeLessThan(0.85);

  // The engine marks <html> around its own transition, and removes it after.
  expect(sawClass).toBe(true);
  expect(classCleared).toBe(true);
  // The scoped rule actually matched: the pseudo animates at the tuned 400ms, not the 250ms UA default.
  expect(durations).toContain('0.4s');
});

test('reduced-motion flips instantly (no crossfade)', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto(PAGE, { waitUntil: 'commit' });

  await seedDark(page);
  const { finalMode, samples, sawClass } = await sampleToLight(page);
  expect(finalMode).toBe('light');
  // No view transition at all: no marker class, and the ::view-transition-old(root) pseudo
  // never fades — it stays pinned near 1 (WebKit reports a constant computed opacity when
  // nothing is animating).
  expect(sawClass).toBe(false);
  if (samples.length) expect(Math.min(...samples)).toBeGreaterThan(0.98);
});
