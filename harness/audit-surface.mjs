// Reusable surface auditor for discovery. Navigates to a URL (optionally opening a
// surface via hover/click), themes light with the real engine, then reports latent
// theme/contrast issues as JSON: washed/low-contrast text (1.4.3) across the full
// scroll range, dark "islands" that should be light, missing focus rings, and
// invisible card surfaces (1.4.11). Read-only — never edits anything.
//
// Usage:
//   node audit-surface.mjs <url> [--label X] [--hover "<sel>"] [--click "<sel>"] [--wait "<sel>"]
import { webkit } from '@playwright/test';
import { loadEngineScript } from './lib/engine.js';
import { PROBE } from './lib/probe-inpage.js';

function arg(name, def) { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : def; }
const url = process.argv[2];
if (!url) { console.error('usage: node audit-surface.mjs <url> [--label X] [--hover sel] [--click sel] [--wait sel]'); process.exit(2); }
const label = arg('--label', url);

const browser = await webkit.launch();
const ctx = await browser.newContext({ storageState: process.env.YTM_AUTH, colorScheme: 'light', viewport: { width: 1280, height: 800 } });
const page = await ctx.newPage();
await page.addInitScript({ content: loadEngineScript() });
await page.addInitScript({ content: PROBE });

const T = 8000;
const result = { label, url, mode: null, opened: true, failures: [], coverage: {} };
try {
  await page.goto(url, { waitUntil: 'commit' });
  await page.waitForFunction(() => document.documentElement.getAttribute('data-ytm-mode') === 'light', null, { timeout: 20000 }).catch(() => {});
  await page.waitForFunction(() => window.__ytmProbe && window.__ytmProbe.scrollInfo().max >= 0, null, { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(5000);

  // optional interaction to reveal a popup / dialog / page
  const hov = arg('--hover'), clk = arg('--click'), wait = arg('--wait');
  try {
    if (hov) await page.locator(hov).first().hover({ timeout: T });
    if (clk) { await page.waitForTimeout(300); await page.locator(clk).first().click({ force: true, timeout: T }); }
    if (wait) await page.locator(wait).first().waitFor({ state: 'visible', timeout: T });
    await page.waitForTimeout(1500);
  } catch (e) { result.opened = false; result.openError = String(e.message).split('\n')[0]; }

  result.mode = await page.evaluate(() => document.documentElement.getAttribute('data-ytm-mode'));

  // The audit function (text 1.4.3 + dark-island + surface 1.4.11), run at every scroll depth.
  const auditOnce = () => page.evaluate(() => {
    function toRGB(v){var m=v&&v.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/);return m?{r:+m[1],g:+m[2],b:+m[3],a:m[4]===undefined?1:+m[4]}:null;}
    function L(c){var f=[c.r,c.g,c.b].map(function(v){v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4);});return 0.2126*f[0]+0.7152*f[1]+0.0722*f[2];}
    function W(a,b){return (Math.max(L(a),L(b))+0.05)/(Math.min(L(a),L(b))+0.05);}
    function up(e){return e.parentElement||(e.parentNode&&e.parentNode.host)||null;}
    function bgEl(el){for(var e=el;e;e=up(e)){var c=toRGB(getComputedStyle(e).backgroundColor);if(c&&c.a>=1)return {c:c,el:e};}return {c:{r:243,g:243,b:243},el:document.body};}
    function sel(el){var s=el.tagName.toLowerCase();if(el.id)s+='#'+el.id;else if(typeof el.className==='string'&&el.className)s+='.'+el.className.trim().split(/\s+/)[0];return s;}
    var out=[]; var els=document.querySelectorAll('body *');
    for(var i=0;i<els.length;i++){var el=els[i];
      var hasText=false; for(var j=0;j<el.childNodes.length;j++){var n=el.childNodes[j];if(n.nodeType===3&&n.textContent.trim().length>1){hasText=true;break;}}
      if(!hasText) continue;
      var st=getComputedStyle(el); if(st.visibility==='hidden'||st.opacity==='0') continue;
      var r=el.getBoundingClientRect(); if(r.width<8||r.height<6||r.bottom<0||r.top>innerHeight) continue;
      var fg=toRGB(st.color); if(!fg||fg.a===0) continue;
      var bg=bgEl(el).c; var ra=W(fg,bg);
      var fs=parseFloat(st.fontSize)||14; var lg=fs>=24||(fs>=18.66&&(+st.fontWeight)>=700);
      if(ra<(lg?3:4.5)) out.push({kind:'text',sel:sel(el),wcag:+ra.toFixed(2),fg:st.color,bg:'rgb('+bg.r+','+bg.g+','+bg.b+')',text:el.textContent.trim().slice(0,32)});
    }
    // ICON pass (WCAG 1.4.11, 3:1) — meaningful glyphs inside interactive controls.
    // Skip icons sitting OVER media (album art): a white play-triangle on a thumbnail
    // is correct, but its real background is the image + scrim, not the page — measuring
    // it against the page bg is a false positive. Exclude if a media element covers it.
    var media=[].slice.call(document.querySelectorAll('img,yt-img-shadow,[style*="background-image"]')).map(function(m){return m.getBoundingClientRect();}).filter(function(r){return r.width>24&&r.height>24;});
    function overMedia(r){var cx=r.left+r.width/2, cy=r.top+r.height/2; for(var m=0;m<media.length;m++){var b=media[m]; if(cx>=b.left&&cx<=b.right&&cy>=b.top&&cy<=b.bottom) return true;} return false;}
    var icons=document.querySelectorAll('button svg, a svg, [role="button"] svg, tp-yt-paper-icon-button svg, yt-icon svg, ytmusic-play-button-renderer svg');
    for(var k=0;k<icons.length;k++){var ic=icons[k];var r2=ic.getBoundingClientRect();
      if(r2.width<10||r2.width>56||r2.height<10||r2.bottom<0||r2.top>innerHeight) continue;
      if(overMedia(r2)) continue;
      var ist=getComputedStyle(ic); if(ist.visibility==='hidden'||(+ist.opacity)<0.4) continue;
      var fc=ist.fill&&ist.fill!=='none'&&ist.fill!=='rgba(0, 0, 0, 0)'?toRGB(ist.fill):null;
      if(!fc) fc=toRGB(ist.color);
      if(!fc||fc.a<0.4) continue;
      var ibg=bgEl(ic).c; var ir=W(fc,ibg);
      if(ir<3) out.push({kind:'icon',sel:sel(ic.closest('button,a,[role="button"],tp-yt-paper-icon-button,yt-icon')||ic),wcag:+ir.toFixed(2),fg:'fill '+(ist.fill||ist.color),bg:'rgb('+ibg.r+','+ibg.g+','+ibg.b+')',text:(ic.closest('[aria-label]')&&ic.closest('[aria-label]').getAttribute('aria-label')||'icon').slice(0,32)});
    }
    return out;
  });

  const seen = new Set(); const push = (arr) => { for (const f of arr) { const k = f.sel + '|' + (f.text || '') + '|' + f.bg; if (!seen.has(k)) { seen.add(k); result.failures.push(f); } } };

  const info = await page.evaluate(() => window.__ytmProbe.scrollInfo());
  result.coverage.scrollMax = info.max;
  let y = 0, steps = 0, lastMax = -1;
  for (; steps < 30; steps++) {
    await page.evaluate((yy) => window.__ytmProbe.scrollTo(yy), y);
    await page.waitForTimeout(550);
    push(await auditOnce());
    const inf = await page.evaluate(() => window.__ytmProbe.scrollInfo());
    if (y >= inf.max - 2) { if (inf.max <= lastMax + 2) break; lastMax = inf.max; }
    y = Math.min(inf.max, y + 640);
  }
  result.coverage.scrollSteps = steps + 1;
} catch (e) {
  result.fatal = String(e.message).split('\n')[0];
}
await browser.close();
console.log(JSON.stringify(result, null, 2));
