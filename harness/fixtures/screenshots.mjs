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
}

async function goHome(p) {
  await p.goto(BASE + '/', { waitUntil: 'commit' });
  await p.waitForSelector('ytmusic-player-bar', { timeout: 10000 }).catch(() => {});
  await p.waitForTimeout(6500);
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
  storageState: process.env.YTM_AUTH || './auth.json',
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

  // 5: tight crop of just the now-playing bar (fake track "Coastline Signal").
  await goHome(p);
  {
    const bar = p.locator('ytmusic-player-bar');
    try {
      await bar.waitFor({ state: 'visible', timeout: 5000 });
      await bar.screenshot({ path: file('05-now-playing-bar.png') });
      record(new URL('05-now-playing-bar.png', OUT));
    } catch { notes.push('05: ytmusic-player-bar not visible — skipped'); }
  }

  // 6: expanded player / now-playing page. Try the expand chevron (visible instance),
  // fall back to the player-bar thumbnail — both toggle the full player page.
  await goHome(p);
  {
    try {
      let opened = await clickFirstVisible(
        p,
        'ytmusic-player-bar .toggle-player-page-button, button[aria-label*="player page" i], .expand-button',
      );
      if (!opened) opened = await clickFirstVisible(p, 'ytmusic-player-bar img.image');
      if (!opened) throw new Error('no visible expand trigger');
      await p.waitForFunction(() => {
        const e = document.querySelector('ytmusic-player-page');
        return e && e.getBoundingClientRect().height > 200;
      }, { timeout: 5000 });
      await p.waitForTimeout(1000);
      await settle(p);
      await p.screenshot({ path: file('06-expanded-player.png') });
      record(new URL('06-expanded-player.png', OUT));
    } catch (e) { notes.push('06: expanded player did not open — skipped (' + e.message.split('\n')[0] + ')'); }
  }

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
