// Curated, deterministic light-theme screenshots of the YT Music macOS app,
// served entirely from the fake-user fixture layer (Alex Rivera / Nova Sonder — no real PII).
// Idempotent: overwrites fixtures/screenshots/*.png each run. Run: node fixtures/screenshots.mjs
import { webkit } from '@playwright/test';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { loadEngineScript } from '../lib/engine.js';
import { installFixture } from './fixture.mjs';

const OUT = new URL('./screenshots/', import.meta.url);
const BASE = 'https://music.youtube.com';
const ENGINE = loadEngineScript();
fs.mkdirSync(OUT, { recursive: true });

const notes = [];   // shots skipped / issues
const shots = [];   // { file, bytes }

// Settle: engine has flipped the surface to light, then a short beat for layout.
async function settle(p) {
  try {
    await p.waitForFunction(
      () => document.documentElement.getAttribute('data-ytm-mode') === 'light',
      { timeout: 8000 },
    );
  } catch { notes.push('engine did not report data-ytm-mode=light within 8s (continuing)'); }
  await p.waitForTimeout(700);
  // Suppress the engine's :focus-visible ring. The shots that open a menu (account, track ⋮)
  // do it programmatically, which leaves a keyboard-focus ring a mouse user never sees — it
  // just uglifies the marketing image. Persistent style tag, so it also covers menus opened
  // after this call. Same high-specificity reset the test harness uses (out-specifies the
  // engine's scoped `html[data-ytm-mode="light"] [tabindex]:focus-visible`).
  await p.addStyleTag({
    content: 'html[data-ytm-mode][data-ytm-mode][data-ytm-mode] *:focus-visible,' +
             'html[data-ytm-mode][data-ytm-mode][data-ytm-mode] *:focus { outline: none !important; }',
  }).catch(() => {});
}

async function goHome(p) {
  await p.goto(BASE + '/', { waitUntil: 'commit' });
  await p.waitForSelector('ytmusic-player-bar', { timeout: 10000 }).catch(() => {});
  await p.waitForTimeout(6500);
  await settle(p);
}

// Seed a now-playing track. A cold home load never populates the player bar (the fake rows
// don't start playback and media is blocked), so navigate to a watch URL — the SPA fetches
// next+player from the fixtures, filling the bar and rendering the full player page. Mirrors
// screens.js openPlayerPage. Also hides the "media blocked" error toast (a harness-only
// artifact — real playback never errors) so the marketing shots stay clean.
async function seedPlayback(p) {
  await p.goto(BASE + '/watch?v=dQw4w9WgXcQ', { waitUntil: 'commit' });
  await p.waitForFunction(() => {
    const t = document.querySelector('ytmusic-player-bar .content-info-wrapper .title');
    return t && t.textContent.trim().length > 0;
  }, { timeout: 15000 }).catch(() => {});
  await p.addStyleTag({ content: 'tp-yt-paper-toast, ytmusic-notification-action-renderer, yt-notification-action-renderer { display: none !important; }' }).catch(() => {});
  await settle(p);
}

// Click the first selector match that is actually visible (YTM ships hidden duplicate
// controls for its fullscreen mode; `.first()` alone often grabs a 0-box ghost).
async function clickFirstVisible(p, selector, opts = {}) {
  const loc = p.locator(selector);
  const n = await loc.count();
  for (let i = 0; i < n; i++) {
    const el = loc.nth(i);
    if (await el.isVisible().catch(() => false)) {
      await el.click({ timeout: 4000, ...opts });
      return true;
    }
  }
  return false;
}

function record(name) {
  const path = fileURLToPath(name);
  const bytes = fs.existsSync(path) ? fs.statSync(path).size : 0;
  shots.push({ file: path.split('/').pop(), bytes });
  if (bytes <= 5120) notes.push(`${path.split('/').pop()} is ${bytes}B (<=5KB) — likely blank/failed`);
  return bytes;
}
const file = (n) => fileURLToPath(new URL(n, OUT));

const b = await webkit.launch();
const ctx = await b.newContext({
  storageState: process.env.YTM_AUTH || undefined,   // fixtures fake all content — no real login needed
  colorScheme: 'light',
  viewport: { width: 1280, height: 800 },
});
await installFixture(ctx);
await ctx.addInitScript({ content: ENGINE });
const p = await ctx.newPage();

try {
  // 1-4: route-reachable full-window surfaces.
  for (const [name, path] of [
    ['01-home', '/'],
    ['02-explore', '/explore'],
    ['03-library', '/library'],
    ['04-search', '/search?q=daft%20punk'],
  ]) {
    await p.goto(BASE + path, { waitUntil: 'commit' });
    await p.waitForTimeout(6500);
    await settle(p);
    await p.screenshot({ path: file(`${name}.png`) });
    record(new URL(`${name}.png`, OUT));
  }

  // 5: tight crop of just the now-playing bar. Seed playback first (a cold home load
  // never populates it — see seedPlayback).
  await seedPlayback(p);
  {
    const bar = p.locator('ytmusic-player-bar:visible').first();
    try {
      await bar.waitFor({ state: 'visible', timeout: 8000 });
      await bar.screenshot({ path: file('05-now-playing-bar.png') });
      record(new URL('05-now-playing-bar.png', OUT));
    } catch (e) { notes.push('05: player bar not visible — skipped (' + e.message.split('\n')[0] + ')'); }
  }

  // (No expanded-player marketing shot: under the hermetic fixture the player page's main
  // media region is a blocked <video> that renders as a blank box in light — not
  // marketing-quality. Shot 05 (now-playing bar crop) covers "playback" for the showcase,
  // and regression covers the player page functionally via modal:player-page. Restore this
  // if the fixture is ever taught to render album art in Song mode.)

  // 7: account menu (should render "Alex Rivera").
  await goHome(p);
  {
    try {
      const opened = await clickFirstVisible(
        p,
        'button[aria-label="Open avatar menu" i], button[aria-label*="Account" i], ytmusic-nav-bar img.yt-img-shadow, #avatar-btn',
      );
      if (!opened) throw new Error('no visible avatar trigger');
      await p.locator('ytmusic-multi-page-menu-renderer, tp-yt-iron-dropdown, ytmusic-menu-popup-renderer')
        .first().waitFor({ state: 'visible', timeout: 5000 });
      await p.waitForTimeout(500);
      await p.screenshot({ path: file('07-account-menu.png') });
      record(new URL('07-account-menu.png', OUT));
    } catch (e) { notes.push('07: account menu did not open — skipped (' + e.message.split('\n')[0] + ')'); }
  }

  // 8: track action (⋮) context menu on a Quick-picks row. Scope to shelf content so we
  // grab a real on-screen row, not a hidden queue/miniplayer item.
  await goHome(p);
  {
    try {
      const item = p.locator('ytmusic-shelf-renderer ytmusic-responsive-list-item-renderer, #contents ytmusic-responsive-list-item-renderer')
        .filter({ has: p.locator('button[aria-label="Action menu" i]') }).first();
      await item.scrollIntoViewIfNeeded({ timeout: 5000 });
      await item.hover({ timeout: 5000 });
      await p.waitForTimeout(300);
      await item.locator('button[aria-label="Action menu" i]').click({ force: true, timeout: 5000 });
      await p.locator('ytmusic-menu-popup-renderer').first().waitFor({ state: 'visible', timeout: 5000 });
      await p.waitForTimeout(400);
      await p.screenshot({ path: file('08-track-menu.png') });
      record(new URL('08-track-menu.png', OUT));
    } catch { notes.push('08: track action menu did not open — skipped'); }
  }

  // Committed README images (repo-root screenshots/): crisp 2x light-theme captures the README
  // embeds. Generator-emitted (not hand-captured) so `npm run screenshots` keeps them in sync
  // with the theme, and fixture identity (Alex Rivera) so there's no real data. These REPLACE
  // the inherited upstream captures, which were dark-theme AND showed a real account's library
  // (the Control Center / Discord shots were also that account's — OS-level UI this hermetic
  // harness can't reproduce; recapture manually if you want to showcase those features).
  {
    const ROOT = new URL('../../screenshots/', import.meta.url);
    try {
      const hctx = await b.newContext({
        storageState: process.env.YTM_AUTH || undefined,
        colorScheme: 'light',
        viewport: { width: 1312, height: 912 },
        deviceScaleFactor: 2,
      });
      await installFixture(hctx);
      await hctx.addInitScript({ content: ENGINE });
      const hp = await hctx.newPage();
      for (const [name, path] of [
        ['youtube-app', '/'],       // README hero (home)
        ['explore', '/explore'],
        ['library', '/library'],
      ]) {
        try {
          await hp.goto(BASE + path, { waitUntil: 'commit' });
          await hp.waitForTimeout(6500);
          await settle(hp);
          await hp.screenshot({ path: fileURLToPath(new URL(`${name}.png`, ROOT)) });
          record(new URL(`${name}.png`, ROOT));
        } catch (e) { notes.push(`README ${name}.png not captured — ${e.message.split('\n')[0]}`); }
      }
      await hctx.close();
    } catch (e) { notes.push('README images not refreshed — ' + e.message.split('\n')[0]); }
  }

  // Content / PII check: on home the page text should carry the fake identity, never a real name.
  await goHome(p);
  const text = await p.evaluate(() => document.body.innerText);
  const hasFake = /Alex Rivera|Nova Sonder|Coastline Signal/.test(text);
  const leak = /Brian/i.test(text);
  if (!hasFake) notes.push('CONTENT CHECK: home text missing expected fake content (Alex Rivera / Nova Sonder)');
  if (leak) notes.push('!!! REAL-NAME LEAK: "Brian" found in rendered page text');

  console.log('\n=== screenshots ===');
  for (const s of shots) console.log(`  ${s.file}  ${(s.bytes / 1024).toFixed(1)}KB`);
  console.log('\nfake content present on home:', hasFake, '| "Brian" leak:', leak);
  if (notes.length) { console.log('\nnotes:'); for (const n of notes) console.log('  -', n); }
  else console.log('\nnotes: none — all shots captured cleanly');
} finally {
  await b.close();
}
