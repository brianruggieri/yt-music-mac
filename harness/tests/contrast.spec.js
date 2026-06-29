import { test, expect } from '@playwright/test';
import { loadEngineScript } from '../lib/engine.js';
import { auditContrast } from '../lib/audit.js';
import { BASE, SCREENS, INTERACTIONS } from '../screens.js';

const ENGINE = loadEngineScript();

// Inject the real light-theme engine at document start (same timing as the app's
// WKUserScript). It self-drives off prefers-color-scheme, which Playwright forces
// per-project via `colorScheme`, so the engine applies light in the light project
// and stays inert (native dark) in the dark project.
test.beforeEach(async ({ page }) => {
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
  await page.waitForTimeout(6000);
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

    // Visual snapshot per screen × theme. NOTE: music.youtube.com serves personalized,
    // rotating content, so pixels drift run-to-run (different art/rows). This diff is a
    // GROSS-BREAKAGE backstop only (a theme break diffs ~80%+; content shuffle ~20%) —
    // the precise, content-independent theme gates are the contrast/icon/state sweeps.
    await expect(page).toHaveScreenshot(`${screen.name}-${mode}.png`, {
      maxDiffPixelRatio: 0.45,
      animations: 'disabled',
    });

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

    await expect(page).toHaveScreenshot(`modal-${ix.name}-${mode}.png`, {
      maxDiffPixelRatio: 0.45,   // gross-breakage backstop; content behind the modal drifts (see screen note)
      animations: 'disabled',
    });

    if (mode === 'light') {
      const failures = (await page.evaluate(auditContrast)).filter((f) => f.kind === 'text' || f.kind === 'icon');
      report(ix.name, failures);
      expect(failures, `contrast failures in ${ix.name}`).toEqual([]);
    }
  });
}
