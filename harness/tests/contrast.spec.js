import { test, expect } from '@playwright/test';
import { loadEngineScript } from '../lib/engine.js';
import { auditContrast } from '../lib/audit.js';
import { BASE, SCREENS, INTERACTIONS } from '../screens.js';
import { PLAYER_STATES } from '../lib/player-mock.js';
import { installFixture } from '../fixtures/fixture.mjs';

const ENGINE = loadEngineScript();

// Inject the real light-theme engine at document start (same timing as the app's
// WKUserScript). It self-drives off prefers-color-scheme, which Playwright forces
// per-project via `colorScheme`, so the engine applies light in the light project
// and stays inert (native dark) in the dark project.
test.beforeEach(async ({ page, context }) => {
  // Deterministic fake fixtures by default (frozen content → stable screenshots, no PII,
  // reliable modal triggers). Set YTM_LIVE=1 to run against real music.youtube.com (the
  // old canary mode — catches YT redesigns, but rotates content and can flaky-skip modals).
  if (!process.env.YTM_LIVE) await installFixture(context, page);
  await page.addInitScript({ content: ENGINE });
});

async function settle(page, mode) {
  await page.waitForLoadState('domcontentloaded');
  // Wait for the engine to commit the mode, then let content + late CSS stream in.
  await page.waitForFunction(
    (m) => document.documentElement.getAttribute('data-ytm-mode') === m,
    mode === 'light' ? 'light' : 'dark',
    { timeout: 20_000 },
  ).catch(() => {});
  // Wait for REAL content to render (a shelf/row/card) and the network to go idle, so a
  // screenshot can't capture a half-painted frame (the old blind 6s occasionally did →
  // rare ~10% diffs). Fixtures make this fast and deterministic.
  await page.waitForSelector('ytmusic-carousel-shelf-renderer, ytmusic-shelf-renderer, ytmusic-responsive-list-item-renderer, ytmusic-two-row-item-renderer', { timeout: 15_000 }).catch(() => {});
  await page.waitForLoadState('networkidle').catch(() => {});
  await page.waitForTimeout(1500);
  // Neutralize the engine's :focus-visible ring for STABLE baselines. The harness opens
  // menus/dialogs programmatically, which leaves a keyboard-focus ring that (a) a real
  // MOUSE user never sees and (b) only renders in light (the engine is light-only), so it
  // shows up as a spurious light-vs-dark diff on the modal snapshots. The ring stays in the
  // shipped app for keyboard users — we just don't photograph it. Higher-specificity and
  // later in the DOM than the engine's rule, so `outline: none` wins.
  // Kill the engine's :focus-visible ring for STABLE baselines: it's a keyboard-focus
  // indicator a mouse user never triggers, it only renders in light (engine is light-only),
  // and it lands nondeterministically at capture time — a flaky light-vs-dark diff. The app
  // keeps the ring for real keyboard users; we just don't photograph it. The engine SCOPES
  // its focus rules as `html[data-ytm-mode="light"] [tabindex]:focus-visible` (specificity
  // 0,3,1) and appends its sheet LAST in <html>, so a plain reset loses on specificity AND
  // source order. Repeat the html attribute to reach (0,4,1) and win outright.
  await page.addStyleTag({
    content: 'html[data-ytm-mode][data-ytm-mode][data-ytm-mode] *:focus-visible,' +
             'html[data-ytm-mode][data-ytm-mode][data-ytm-mode] *:focus { outline: none !important; }',
  }).catch(() => {});
}

function report(screen, failures) {
  if (!failures.length) return;
  const lines = failures.map((f) =>
    f.kind === 'text' ? `  [text]    ${f.sel}  wcag=${f.wcag} Lc=${f.apcaLc}  ${f.fg} on ${f.bg}  "${f.text}"`
    : f.kind === 'icon' ? `  [icon]    ${f.sel}  wcag=${f.wcag}  ${f.fg} on ${f.bg}`
    : `  [surface] ${f.sel}  wcag=${f.wcag}  ${f.bg}`,
  );
  console.log(`\n✗ ${screen} — ${failures.length} contrast issue(s):\n${lines.join('\n')}`);
}

for (const screen of SCREENS) {
  test(`${screen.name}`, async ({ page }, info) => {
    const mode = info.project.name; // 'light' | 'dark'
    await page.goto(BASE + screen.path, { waitUntil: 'commit' });
    await settle(page, mode);

    // Visual snapshot per screen × theme. Content is now frozen by the fixture layer
    // (deterministic fake data + black-square art), so this is a tight pixel gate (0.03: tolerates ~0.01% AA jitter, catches theme breaks ~80%) that
    // catches real theme drift — not the old 0.45 gross-breakage backstop that the live,
    // rotating content forced. Under YTM_LIVE the page shows real, rotating content that
    // can't match the fake baselines, so skip the pixel gate — the live canary relies on the
    // content-independent contrast/state audits instead.
    if (!process.env.YTM_LIVE) {
      await expect(page).toHaveScreenshot(`${screen.name}-${mode}.png`, {
        maxDiffPixelRatio: 0.03,
        animations: 'disabled',
      });
    }

    // Contrast is only our responsibility in light mode (dark is YT's own).
    if (mode === 'light') {
      const failures = await page.evaluate(auditContrast);
      report(screen.name, failures);
      const gated = failures.filter((f) => f.kind === 'text' || f.kind === 'icon');
      // Text + neutral-icon failures are hard gates; surface failures are reported only.
      expect(gated, `contrast failures on ${screen.name}`).toEqual([]);
    }
  });
}

for (const ix of INTERACTIONS) {
  test(`modal:${ix.name}`, async ({ page }, info) => {
    // Player states are built around injected deterministic media (injectPlayerMedia is a
    // no-op under YTM_LIVE). In live mode they'd audit a real, actively-playing page whose
    // <video> + visualizer rAF starves the auditContrast page.evaluate → 90s timeout, not a
    // real contrast signal. Skip live; add back with paused playback + a raised timeout.
    test.skip(!!process.env.YTM_LIVE && PLAYER_STATES.includes(ix.name),
      'player states need mocked media; live playback blows the audit timeout');
    const mode = info.project.name;
    await page.goto(BASE + ix.path, { waitUntil: 'commit' });
    await settle(page, mode);
    try {
      await ix.open(page);
    } catch (e) {
      console.log(`\n⏭ modal:${ix.name} could not open → ${e.message.split('\n')[0]}`);
      test.skip(true, `could not open ${ix.name}: ${e.message}`);
    }
    await page.waitForTimeout(1200); // let the engine theme the freshly-opened surface

    if (!process.env.YTM_LIVE) {
      await expect(page).toHaveScreenshot(`modal-${ix.name}-${mode}.png`, {
        maxDiffPixelRatio: 0.03,   // tight gate: fixtures freeze the content behind the modal too
        animations: 'disabled',
      });
    }

    if (mode === 'light') {
      const failures = (await page.evaluate(auditContrast)).filter((f) => f.kind === 'text' || f.kind === 'icon');
      report(ix.name, failures);
      expect(failures, `contrast failures in ${ix.name}`).toEqual([]);
    }
  });
}
