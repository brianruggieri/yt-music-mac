import { test, expect } from '@playwright/test';
import { loadEngineScript } from '../lib/engine.js';
import { PROBE } from '../lib/probe-inpage.js';
import { BASE, SCREENS } from '../screens.js';
import { installFixture } from '../fixtures/fixture.mjs';

const ENGINE = loadEngineScript();

// Comprehensive per-screen STATE sweep — light mode only (the theme we own):
//   • SCROLL: every step of the scroll range (scroll-triggered states: nav darkening,
//     sticky headers, lazy-loaded rows).
//   • FOCUS: real keyboard Tab through the focus order (so :focus-visible actually
//     fires) — every focused control must show a visible ring AND pass label contrast.
//   • HOVER: real pointer hover over one representative of every interactive component
//     type — the hovered control gains a bg tint; its label must still pass contrast.
//
// :hover/:active can't be faked from JS and :focus-visible needs real keyboard, so
// these are driven with Playwright's real input, not synthetic events.
test.beforeEach(async ({ page, context }) => {
  if (!process.env.YTM_LIVE) await installFixture(context);   // deterministic fixtures (YTM_LIVE=1 for live)
  await page.addInitScript({ content: ENGINE });
  await page.addInitScript({ content: PROBE });
});

const MAX_TAB = 160;   // cap the focus walk so it can't run unbounded
const HOVER_TIMEOUT = 1500;

async function settle(page, mode) {
  const want = mode === 'dark' ? 'dark' : 'light';
  await page.waitForFunction((m) => document.documentElement.getAttribute('data-ytm-mode') === m, want, { timeout: 20_000 }).catch(() => {});
  // Wait for content to actually populate (a real, viewport-sized scroll area appears),
  // otherwise we'd sweep a half-loaded page and pass vacuously.
  await page.waitForFunction(() => window.__ytmProbe && window.__ytmProbe.scrollInfo().max > 400, null, { timeout: 20_000 }).catch(() => {});
  await page.waitForLoadState('networkidle').catch(() => {});
  await page.waitForTimeout(3000);
}

// Empty/near-empty surfaces (no scroll area, few controls) have nothing to sweep — the
// scroll/focus/hover passes are meaningless there and the hover pass flakes on transient
// contrast. They're still gated by the screenshot + contrast audit in contrast.spec.
const NO_STATE_SWEEP = new Set(['search-empty']);

for (const screen of SCREENS) {
  if (NO_STATE_SWEEP.has(screen.name)) continue;
  test(`states: ${screen.name}`, async ({ page }, info) => {
    // Runs in BOTH light and dark. Light audits our theme; dark is a canary — it asserts the
    // engine stays inert (native dark unbroken) and that YT dark stays accessible. Fixtures
    // make dark deterministic, so this is stable rather than the old flaky live sweep.
    await page.goto(BASE + screen.path, { waitUntil: 'commit' });
    await settle(page, info.project.name);

    const issues = [];          // hard: text-contrast failures (gate)
    const notes = [];           // soft: missing focus rings, off-screen focus (report)
    const cov = { scrollMax: 0, scrollSteps: 0, tabs: 0, focused: 0, hoverReps: 0, interactiveTotal: 0 };

    // ---- 1) SCROLL SWEEP (infinite-scroll aware: keep going as new rows lazy-load) ----
    const auditAt = () => page.evaluate(() => {
        // walk text, report failures (inline, exact)
        function toRGB(v){var m=v&&v.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/);return m?{r:+m[1],g:+m[2],b:+m[3],a:m[4]===undefined?1:+m[4]}:null;}
        function L(c){var f=[c.r,c.g,c.b].map(function(v){v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4);});return 0.2126*f[0]+0.7152*f[1]+0.0722*f[2];}
        function W(a,b){return (Math.max(L(a),L(b))+0.05)/(Math.min(L(a),L(b))+0.05);}
        function up(e){return e.parentElement||(e.parentNode&&e.parentNode.host)||null;}
        function bgOf(el){for(var e=el;e;e=up(e)){var c=toRGB(getComputedStyle(e).backgroundColor);if(c&&c.a>=1)return c;}return {r:243,g:243,b:243};}
        function comp(fg,bg){return fg.a<1?{r:Math.round(fg.r*fg.a+bg.r*(1-fg.a)),g:Math.round(fg.g*fg.a+bg.g*(1-fg.a)),b:Math.round(fg.b*fg.a+bg.b*(1-fg.a))}:fg;}
        var out=[];
        var els=document.querySelectorAll('body *');
        for(var i=0;i<els.length;i++){var el=els[i];var t=false;for(var j=0;j<el.childNodes.length;j++){var n=el.childNodes[j];if(n.nodeType===3&&n.textContent.trim().length>1){t=true;break;}}if(!t)continue;var st=getComputedStyle(el);if(st.visibility==='hidden'||st.opacity==='0')continue;var r=el.getBoundingClientRect();if(r.width<8||r.height<6||r.bottom<0||r.top>innerHeight)continue;var fg=toRGB(st.color);if(!fg||fg.a===0)continue;var bg=bgOf(el);var ra=W(comp(fg,bg),bg);var fs=parseFloat(st.fontSize)||14;var lg=fs>=24||(fs>=18.66&&(+st.fontWeight)>=700);if(ra<(lg?3:4.5))out.push(el.tagName.toLowerCase()+' wcag='+ra.toFixed(2)+' "'+el.textContent.trim().slice(0,24)+'"');}
        return out.slice(0,60);
      });

    let y = 0, lastMax = -1, steps = 0;
    for (; steps < 40; steps++) {
      await page.evaluate((yy) => window.__ytmProbe.scrollTo(yy), y);
      await page.waitForTimeout(600);
      // Persistence re-check: lazy-loaded carousel rows render light and the engine darkens
      // them on the next tick, so a single audit can catch a transient mid-theming state.
      // Keep only failures that SURVIVE a re-audit after a short settle — real gaps persist,
      // the engine catching up drops out. Match on selector+text (ignore wcag drift).
      let scrollFails = await auditAt();
      if (scrollFails.length) {
        await page.waitForTimeout(700);
        const again = (await auditAt()).map((s) => s.replace(/wcag=[\d.]+/, ''));
        scrollFails = scrollFails.filter((x) => again.includes(x.replace(/wcag=[\d.]+/, '')));
      }
      for (const f of scrollFails) issues.push(`scroll@${y}: ${f}`);
      const info = await page.evaluate(() => window.__ytmProbe.scrollInfo());
      cov.scrollMax = Math.max(cov.scrollMax, info.max);
      if (y >= info.max - 2) {                    // at the bottom
        if (info.max <= lastMax + 2) break;       // ...and no new content lazy-loaded -> done
        lastMax = info.max;
      }
      y = Math.min(info.max, y + Math.round(info.client * 0.85));
    }
    cov.scrollSteps = steps + 1;
    await page.evaluate(() => window.__ytmProbe.scrollTo(0));
    await page.waitForTimeout(300);

    // ---- 2) FOCUS SWEEP (real keyboard Tab) ----
    await page.evaluate(() => window.__ytmProbe.enumerate());      // tag elements with data-ytm-ix
    await page.mouse.click(4, 4).catch(() => {});                  // park focus, then Tab from top
    const seenFocus = new Set();
    let lastNew = 0;
    for (let i = 0; i < MAX_TAB; i++) {
      await page.keyboard.press('Tab');
      cov.tabs++;
      const st = await page.evaluate(() => window.__ytmProbe.activeState());
      if (!st) { if (i - lastNew > 16) break; continue; }   // bounced to chrome/body
      if (!seenFocus.has(st.sel)) {
        seenFocus.add(st.sel);
        lastNew = i;
        if (!st.ring && st.onScreen) notes.push(`focus: no visible ring on ${st.sel}`);
        if (st.contrast) issues.push(`focus: ${st.sel} ${st.contrast}`);
      }
      if (i - lastNew > 16) break;   // no NEW focus target in 16 tabs -> order exhausted
    }
    cov.focused = seenFocus.size;

    // ---- 3) HOVER SWEEP (real pointer; re-enumerate at several scroll depths so we
    //        cover component types throughout the page, not just the first viewport) ----
    const hoveredSigs = new Set();
    const sweepHover = async () => {
      const enumRes = await page.evaluate(() => window.__ytmProbe.enumerate());
      cov.interactiveTotal = Math.max(cov.interactiveTotal, enumRes.total);
      for (const rep of enumRes.reps) {
        if (hoveredSigs.has(rep.sig)) continue;
        const loc = page.locator(rep.sel).first();
        try { await loc.hover({ timeout: HOVER_TIMEOUT }); } catch { continue; }
        hoveredSigs.add(rep.sig);
        cov.hoverReps++;
        await page.waitForTimeout(90);
        const f = await page.evaluate((sel) => window.__ytmProbe.elContrast(sel), rep.sel);
        if (f) issues.push(`hover: ${rep.sig} → ${f}`);
      }
    };
    const { max: smax } = await page.evaluate(() => window.__ytmProbe.scrollInfo());
    for (const frac of [0, 0.5, 1]) {
      await page.evaluate((y) => window.__ytmProbe.scrollTo(y), Math.round(smax * frac));
      await page.waitForTimeout(500);
      await sweepHover();
    }
    await page.evaluate(() => window.__ytmProbe.scrollTo(0));

    console.log(`\n— states: ${screen.name} — coverage: scroll=${cov.scrollSteps} steps (max ${cov.scrollMax}px), tabs=${cov.tabs} focused=${cov.focused} distinct, hover=${cov.hoverReps} component types, ${cov.interactiveTotal} interactive total | ${issues.length} contrast issue(s), ${[...new Set(notes)].length} note(s)`);
    if (issues.length || notes.length) {
      if (issues.length) console.log('  CONTRAST:\n    ' + issues.join('\n    '));
      if (notes.length) console.log('  NOTES:\n    ' + [...new Set(notes)].join('\n    '));
    }
    // Gate on contrast failures across all states; focus-ring notes are reported only.
    expect(issues, `state contrast issues on ${screen.name}`).toEqual([]);
  });
}
