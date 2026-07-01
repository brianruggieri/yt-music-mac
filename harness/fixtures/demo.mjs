import { webkit } from '@playwright/test';
import { loadEngineScript } from '../lib/engine.js';
import { installFixture } from './fixture.mjs';
const ENGINE = loadEngineScript();

const b = await webkit.launch();
const ctx = await b.newContext({ storageState: process.env.YTM_AUTH || './auth.json', colorScheme:'light', viewport:{width:1280,height:800} });
await installFixture(ctx);
await ctx.addInitScript({ content: ENGINE });
const p = await ctx.newPage();
for (const [name, path] of [['home','/'],['explore','/explore'],['library','/library'],['search','/search?q=daft%20punk']]) {
  await p.goto('https://music.youtube.com'+path, { waitUntil:'commit' });
  await p.waitForTimeout(6500);
  await p.screenshot({ path: `fixtures/demo-${name}.png` });
}
const t = await p.evaluate(() => [...document.querySelectorAll('.title')].map(e=>e.textContent.trim()).filter(Boolean).slice(0,6));
console.log('sample titles:', JSON.stringify(t));
await b.close();
