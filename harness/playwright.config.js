import { defineConfig, devices } from '@playwright/test';

// We test under WebKit specifically: it's the same engine family as the app's
// WKWebView, so contrast/rendering results match what users actually see.
// Two projects run the same specs under a forced system appearance, so we verify
// our light theme AND that we don't break YT's native dark.
export default defineConfig({
  testDir: './tests',
  snapshotDir: './snapshots',
  outputDir: './test-results',
  timeout: 90_000,
  expect: { timeout: 15_000 },
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
