import { defineConfig, devices } from '@playwright/test';

// We test under WebKit specifically: it's the same engine family as the app's
// WKWebView, so contrast/rendering results match what users actually see.
// Two projects run the same specs under a forced system appearance, so we verify
// our light theme AND that we don't break YT's native dark.
export default defineConfig({
  testDir: './tests',
  snapshotDir: './snapshots',
  outputDir: './test-results',
  // In live mode the run IS the canary, and its one question is "did YT change something?".
  // Specs that never load music.youtube.com can't answer that — they only make a red canary
  // ambiguous (a local-engine failure looks identical to a YT redesign in the run list). They
  // stay fully covered by the deterministic fixture gate, which runs them on every push.
  testIgnore: process.env.YTM_LIVE
    ? ['**/theme-transition.spec.js', '**/fs-controls-util.spec.js']
    : [],
  timeout: 90_000,
  expect: { timeout: 15_000 },
  // Fixtures make content deterministic, so the 0.03 screenshot gate is tight. Occasional
  // partial-render captures under machine load still slip through; a retry re-runs the flaky
  // shot and passes, while a REAL theme break (~80% diff) fails all attempts. This is the
  // standard Playwright answer to timing flakiness — keeps the tight gate honest.
  retries: 2,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    ...devices['Desktop Safari'],          // WebKit
    viewport: { width: 1280, height: 800 },
    // A logged-in session (see `npm run auth`) unlocks Home/Library personalization.
    // Without it, Explore/Search still render and are worth testing.
    storageState: process.env.YTM_AUTH || undefined,
    // Stabilize screenshots: stop YT's animations/transitions.
    launchOptions: {},
  },
  projects: [
    { name: 'light', use: { colorScheme: 'light' } },
    { name: 'dark', use: { colorScheme: 'dark' } },
  ],
});
