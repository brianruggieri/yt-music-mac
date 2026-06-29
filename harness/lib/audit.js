// Independent in-page contrast verifier. Runs via page.evaluate() inside WebKit
// (WebKit has no CDP DOMSnapshot, so we walk the live DOM — YT Music uses Shady
// DOM / light DOM, so a plain querySelectorAll reaches everything). This deliberately
// does NOT reuse the engine's own audit — we check the engine's output from the
// outside. Returns a list of { kind, sel, ... } failures (empty = clean).
//
// Two WCAG checks:
//   1.4.3  text contrast        — text vs its effective background (4.5:1 / 3:1 large)
//   1.4.11 non-text contrast    — a card/button surface vs the surface behind it (best-effort)
// Also reports APCA Lc for each text failure (more accurate across polarities).
export function auditContrast() {
  function toRGB(v) {
    const m = v && v.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/);
    return m ? { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] } : null;
  }
  function relLum(c) {
    const f = [c.r, c.g, c.b].map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2];
  }
  function wcag(a, b) { const l1 = relLum(a), l2 = relLum(b); return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05); }
  function apca(txt, bg) {
    const lin = (c) => Math.pow(c / 255, 2.4);
    const Y = (c) => 0.2126729 * lin(c.r) + 0.7151522 * lin(c.g) + 0.0721750 * lin(c.b);
    const clamp = (y) => (y >= 0.022 ? y : y + Math.pow(0.022 - y, 1.414));
    let Yt = clamp(Y(txt)), Yb = clamp(Y(bg));
    if (Math.abs(Yb - Yt) < 0.0005) return 0;
    let C;
    if (Yb > Yt) { C = (Math.pow(Yb, 0.56) - Math.pow(Yt, 0.57)) * 1.14; C = C < 0.001 ? 0 : C - 0.027; }
    else { C = (Math.pow(Yb, 0.65) - Math.pow(Yt, 0.62)) * 1.14; C = C > -0.001 ? 0 : C + 0.027; }
    return Math.round(C * 100);
  }
  function up(e) { return e.parentElement || (e.parentNode && e.parentNode.host) || null; }
  function effBg(el) {
    for (let e = el; e; e = up(e)) { const c = toRGB(getComputedStyle(e).backgroundColor); if (c && c.a >= 1) return c; }
    return toRGB(getComputedStyle(document.body).backgroundColor) || { r: 243, g: 243, b: 243 };
  }
  function sel(el) {
    let s = el.tagName.toLowerCase();
    if (el.id) s += '#' + el.id;
    else if (typeof el.className === 'string' && el.className) s += '.' + el.className.trim().split(/\s+/)[0];
    return s;
  }
  function vis(st, r) {
    return st.visibility !== 'hidden' && st.opacity !== '0' && r.width >= 8 && r.height >= 6 && r.bottom > 0 && r.top < innerHeight;
  }

  const failures = [];

  // --- 1.4.3 text contrast ---
  for (const el of document.querySelectorAll('body *')) {
    let hasText = false;
    for (const n of el.childNodes) if (n.nodeType === 3 && n.textContent.trim().length > 1) { hasText = true; break; }
    if (!hasText) continue;
    const st = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    if (!vis(st, r)) continue;
    const fg = toRGB(st.color); if (!fg || fg.a === 0) continue;
    const bg = effBg(el);
    const fs = parseFloat(st.fontSize) || 14;
    const large = fs >= 24 || (fs >= 18.66 && (+st.fontWeight) >= 700);
    const ratio = wcag(fg, bg);
    const lc = Math.abs(apca(fg, bg));
    if (ratio < (large ? 3 : 4.5)) {
      failures.push({
        kind: 'text', sel: sel(el),
        wcag: +ratio.toFixed(2), apcaLc: lc,
        fg: st.color, bg: `rgb(${bg.r},${bg.g},${bg.b})`,
        text: el.textContent.trim().slice(0, 40),
      });
    }
  }

  // --- 1.4.11 non-text (surface) contrast, best-effort ---
  // A card/button (has border-radius + its own opaque light fill, not a ripple/overlay)
  // whose fill barely differs from the surface behind it.
  for (const el of document.querySelectorAll('body *')) {
    const cls = typeof el.className === 'string' ? el.className : '';
    if (/TouchFeedback|ripple|overlay/i.test(cls)) continue;
    const st = getComputedStyle(el);
    if (st.position === 'absolute' || st.position === 'fixed') continue;
    if ((parseFloat(st.borderTopLeftRadius) || 0) < 4) continue;
    const bg = toRGB(st.backgroundColor); if (!bg || bg.a < 1) continue;
    const bgL = relLum(bg); if (bgL < 0.6) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 48 || r.height < 22 || r.width > 1000 || !vis(st, r)) continue;
    if (parseFloat(st.borderTopWidth) > 0) { const bc = toRGB(st.borderTopColor); if (bc && bc.a > 0.06) continue; }
    const parent = up(el); if (!parent) continue;
    const pL = relLum(effBg(parent));
    const ratio = wcag(bg, { r: Math.round(pL * 255), g: Math.round(pL * 255), b: Math.round(pL * 255) });
    if (ratio < 1.35) {
      failures.push({ kind: 'surface', sel: sel(el), wcag: +ratio.toFixed(2), bg: st.backgroundColor });
    }
  }

  // --- 1.4.11 icon contrast (3:1) — meaningful glyphs inside interactive controls ---
  // Only NEUTRAL (near-grayscale) glyphs are gated: those are theme-driven and must
  // contrast. Excluded as non-bugs: icons over media (white glyph on art + scrim — real
  // bg is the image, not the page), disabled controls (WCAG-exempt), and saturated/brand
  // glyphs (semantic colour like a green rank arrow, conveyed redundantly by text).
  const media = [].slice.call(document.querySelectorAll('img,yt-img-shadow,[style*="background-image"]'))
    .map((m) => m.getBoundingClientRect()).filter((r) => r.width > 24 && r.height > 24);
  const overMedia = (r) => { const cx = r.left + r.width / 2, cy = r.top + r.height / 2; return media.some((b) => cx >= b.left && cx <= b.right && cy >= b.top && cy <= b.bottom); };
  for (const ic of document.querySelectorAll('button svg, a svg, [role="button"] svg, tp-yt-paper-icon-button svg, yt-icon svg, ytmusic-play-button-renderer svg')) {
    const r = ic.getBoundingClientRect();
    if (r.width < 10 || r.width > 56 || r.height < 10 || r.bottom < 0 || r.top > innerHeight) continue;
    if (overMedia(r)) continue;
    const host = ic.closest('button,a,[role="button"],tp-yt-paper-icon-button');
    if (host && (host.disabled || host.getAttribute('aria-disabled') === 'true')) continue;   // disabled is exempt
    const st = getComputedStyle(ic);
    if (st.visibility === 'hidden' || (+st.opacity) < 0.4) continue;
    let fc = st.fill && st.fill !== 'none' && st.fill !== 'rgba(0, 0, 0, 0)' ? toRGB(st.fill) : null;
    if (!fc) fc = toRGB(st.color);
    if (!fc || fc.a < 0.4) continue;
    if (Math.max(fc.r, fc.g, fc.b) - Math.min(fc.r, fc.g, fc.b) > 40) continue;   // saturated → semantic, exempt
    const bg = effBg(ic);
    const ratio = wcag(fc, bg);
    if (ratio < 3) failures.push({ kind: 'icon', sel: sel(host || ic), wcag: +ratio.toFixed(2), fg: `fill ${st.fill || st.color}`, bg: `rgb(${bg.r},${bg.g},${bg.b})` });
  }

  return failures;
}
