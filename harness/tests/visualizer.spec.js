import { test, expect } from '@playwright/test';
import { loadEngineScript } from '../lib/engine.js';
import { installFixture } from '../fixtures/fixture.mjs';

const ENGINE = loadEngineScript();

// Gates the "overlay controls stay WHITE over video/visualizer canvas" fix in
// LightThemeEngine.swift: the icon audit's media detection must treat a large <canvas>
// (the MilkDrop visualizer) and <video> as foreground media, so their hover controls are
// whitened — while the same icon OFF the media stays dark on the light page.
//
// The live visualizer needs WebGL + real audio (not reliable headless), so this is a
// SYNTHETIC check: inject a large canvas + two identical dark overlay icons (one over it,
// one off it) into the real, fixture-served YT Music page with the engine running, then
// assert the engine repaints exactly the on-canvas one white.
test.beforeEach(async ({ page, context }) => {
  if (!process.env.YTM_LIVE) await installFixture(context);
  await page.addInitScript({ content: ENGINE });
});

test('visualizer canvas: overlay icon whitened over media, untouched elsewhere', async ({ page }, info) => {
  test.skip(info.project.name !== 'light', 'the engine is inert in dark — nothing to gate');
  await page.goto('https://music.youtube.com/', { waitUntil: 'commit' });
  await page.waitForFunction(() => document.documentElement.getAttribute('data-ytm-mode') === 'light', null, { timeout: 20_000 });
  await page.waitForTimeout(3000);

  await page.evaluate(() => {
    const NS = 'http://www.w3.org/2000/svg';
    const mk = (left, id) => {
      const btn = document.createElement('button');
      btn.setAttribute('aria-label', id);
      btn.style.cssText = `position:fixed; left:${left}px; top:120px; z-index:5;`;
      const svg = document.createElementNS(NS, 'svg');
      svg.setAttribute('width', '24'); svg.setAttribute('height', '24');
      svg.style.fill = 'rgb(20,20,20)';
      const path = document.createElementNS(NS, 'path');
      path.setAttribute('d', 'M2 2h20v20H2z');
      svg.appendChild(path); btn.appendChild(svg);
      document.body.appendChild(btn);
      return svg;
    };
    const canvas = document.createElement('canvas');
    canvas.width = 1280; canvas.height = 720;
    canvas.style.cssText = 'position:fixed; left:100px; top:100px; width:900px; height:500px; z-index:1; background:#111;';
    document.body.appendChild(canvas);
    window.__overCanvas = mk(500, 'viz-test-over');   // centre inside the canvas box
    window.__offCanvas = mk(1150, 'viz-test-off');    // centre outside it
  });
  await page.waitForTimeout(2500);   // a few engine ticks (audit + icon pass)

  const res = await page.evaluate(() => ({
    over: getComputedStyle(window.__overCanvas).fill,
    off: getComputedStyle(window.__offCanvas).fill,
  }));
  expect(res.over, 'icon over the canvas must be whitened like dark mode').toBe('rgb(255, 255, 255)');
  expect(res.off, 'icon off the canvas must stay dark on the light page').toBe('rgb(20, 20, 20)');
});
