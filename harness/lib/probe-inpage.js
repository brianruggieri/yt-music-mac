// In-page probe, injected once via addInitScript. Exposes window.__ytmProbe with
// pedantic helpers the state sweep calls. All contrast math is WCAG-exact; the
// element walk pierces nothing special because YT uses light/Shady DOM.
//
// IMPORTANT on pseudo-states: :hover and :active CANNOT be triggered from JS
// (synthetic MouseEvents don't set the pseudo-class) — the spec drives those with
// Playwright's real pointer. :focus-visible only matches keyboard focus, so the spec
// drives focus with real Tab presses. This file just measures the resulting state.
export const PROBE = String.raw`
(function () {
  function toRGB(v) {
    var m = v && v.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/);
    return m ? { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] } : null;
  }
  function relLum(c) {
    var f = [c.r, c.g, c.b].map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2];
  }
  function wcag(a, b) { var l1 = relLum(a), l2 = relLum(b); return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05); }
  function apca(txt, bg) {
    var lin = function (c) { return Math.pow(c / 255, 2.4); };
    var Y = function (c) { return 0.2126729 * lin(c.r) + 0.7151522 * lin(c.g) + 0.0721750 * lin(c.b); };
    var clamp = function (y) { return y >= 0.022 ? y : y + Math.pow(0.022 - y, 1.414); };
    var Yt = clamp(Y(txt)), Yb = clamp(Y(bg)), C;
    if (Math.abs(Yb - Yt) < 0.0005) return 0;
    if (Yb > Yt) { C = (Math.pow(Yb, 0.56) - Math.pow(Yt, 0.57)) * 1.14; C = C < 0.001 ? 0 : C - 0.027; }
    else { C = (Math.pow(Yb, 0.65) - Math.pow(Yt, 0.62)) * 1.14; C = C > -0.001 ? 0 : C + 0.027; }
    return Math.round(C * 100);
  }
  function up(e) { return e.parentElement || (e.parentNode && e.parentNode.host) || null; }
  function effBg(el) {
    for (var e = el; e; e = up(e)) { var c = toRGB(getComputedStyle(e).backgroundColor); if (c && c.a >= 1) return c; }
    return toRGB(getComputedStyle(document.body).backgroundColor) || { r: 243, g: 243, b: 243 };
  }
  function selOf(el) {
    var s = el.tagName.toLowerCase();
    if (el.id) s += '#' + el.id;
    else if (typeof el.className === 'string' && el.className) s += '.' + el.className.trim().split(/\s+/)[0];
    return s;
  }
  function directText(el) {
    for (var i = 0; i < el.childNodes.length; i++) { var n = el.childNodes[i]; if (n.nodeType === 3 && n.textContent.trim().length > 1) return true; }
    return false;
  }
  // text-contrast failure for a single element with direct text (or null if fine)
  function textFail(el) {
    var st = getComputedStyle(el);
    if (st.visibility === 'hidden' || st.opacity === '0' || !directText(el)) return null;
    var r = el.getBoundingClientRect();
    if (r.width < 8 || r.height < 6 || r.bottom < 0 || r.top > innerHeight) return null;
    var fg = toRGB(st.color); if (!fg || fg.a === 0) return null;
    var bg = effBg(el);
    // Composite translucent text over its background (alpha-blind scoring let YT's
    // near-transparent secondary text pass as solid black — see audit.js).
    var fgC = fg.a < 1
      ? { r: Math.round(fg.r * fg.a + bg.r * (1 - fg.a)), g: Math.round(fg.g * fg.a + bg.g * (1 - fg.a)), b: Math.round(fg.b * fg.a + bg.b * (1 - fg.a)) }
      : fg;
    var fs = parseFloat(st.fontSize) || 14;
    var large = fs >= 24 || (fs >= 18.66 && (+st.fontWeight) >= 700);
    var ratio = wcag(fgC, bg);
    if (ratio < (large ? 3 : 4.5)) {
      return selOf(el) + ' wcag=' + ratio.toFixed(2) + ' Lc=' + Math.abs(apca(fgC, bg)) +
        ' ' + st.color + ' on rgb(' + bg.r + ',' + bg.g + ',' + bg.b + ') "' + el.textContent.trim().slice(0, 28) + '"';
    }
    return null;
  }

  var IX = 'data-ytm-ix';
  var SEL = [
    'a[href]', 'button', '[role="button"]', '[role="link"]', '[role="menuitem"]', '[role="tab"]',
    '[role="checkbox"]', '[role="switch"]', '[role="option"]', 'input', 'select', 'textarea',
    '[tabindex]:not([tabindex="-1"])', 'tp-yt-paper-icon-button', 'tp-yt-paper-item',
    'yt-button-shape', 'ytmusic-chip-cloud-chip-renderer a', 'ytmusic-pivot-bar-item-renderer',
    'ytmusic-toggle-button-renderer', 'ytmusic-play-button-renderer'
  ].join(',');

  // Tag every interactive element with a stable index, return ONE representative per
  // distinct component signature (tag|role|first-class) so the hover sweep covers
  // every component TYPE without a combinatorial blowup over thousands of instances.
  function enumerate() {
    var seen = {}, reps = [], i = 0, total = 0;
    var els = document.querySelectorAll(SEL);
    for (var k = 0; k < els.length; k++) {
      var el = els[k];
      el.setAttribute(IX, i);
      total++;
      var st = getComputedStyle(el), r = el.getBoundingClientRect();
      var vis = r.width > 4 && r.height > 4 && r.bottom > 0 && r.top < innerHeight && st.visibility !== 'hidden' && st.display !== 'none';
      var cls = (typeof el.className === 'string' && el.className) ? el.className.trim().split(/\s+/)[0] : '';
      var sig = el.tagName.toLowerCase() + '|' + (el.getAttribute('role') || '') + '|' + cls;
      if (vis && !seen[sig]) { seen[sig] = 1; reps.push({ sig: sig, sel: '[' + IX + '="' + i + '"]' }); }
      i++;
    }
    return { total: total, reps: reps };
  }

  // Worst contrast failure anywhere inside a host element (for hover/active states,
  // where the host gains a bg tint and its label must still pass).
  function elContrast(sel) {
    var host = document.querySelector(sel); if (!host) return null;
    var f = textFail(host); if (f) return f;
    var ds = host.querySelectorAll('*');
    for (var i = 0; i < ds.length; i++) { f = textFail(ds[i]); if (f) return f; }
    return null;
  }

  // State of the currently keyboard-focused element: does it have a VISIBLE focus
  // indicator (real outline or a focus box-shadow), and does its label pass contrast?
  function activeState() {
    var el = document.activeElement;
    if (!el || el === document.body || el === document.documentElement) return null;
    var st = getComputedStyle(el);
    var ow = parseFloat(st.outlineWidth) || 0;
    var oc = toRGB(st.outlineColor);
    var ringOutline = ow >= 1.5 && st.outlineStyle !== 'none' && oc && oc.a > 0.3;
    var ringShadow = st.boxShadow && st.boxShadow !== 'none';
    var r = el.getBoundingClientRect();
    return {
      sel: selOf(el),
      onScreen: r.width > 2 && r.height > 2 && r.bottom > 0 && r.top < innerHeight,
      ring: !!(ringOutline || ringShadow),
      contrast: elContrast('[' + IX + '="' + (el.getAttribute(IX) || '') + '"]') || textFail(el),
    };
  }

  // Find the REAL main scroll area: the largest scrollable element whose viewport
  // is near full-height (avoids tiny nested scrollers like a 112px sub-panel).
  function findScroller() {
    var best = document.scrollingElement, bestScore = -1;
    var all = document.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var oy = getComputedStyle(el).overflowY;
      if (oy !== 'auto' && oy !== 'scroll') continue;
      var range = el.scrollHeight - el.clientHeight;
      if (range < 80 || el.clientHeight < 400) continue;   // a real, viewport-sized scroller
      var score = range * el.clientHeight;
      if (score > bestScore) { bestScore = score; best = el; }
    }
    return best;
  }
  function scrollInfo() {
    var sc = findScroller();
    return { max: Math.max(0, sc.scrollHeight - sc.clientHeight), client: sc.clientHeight, tag: (sc.tagName || '?').toLowerCase() + (sc.id ? '#' + sc.id : '') };
  }
  function scrollTo(y) { findScroller().scrollTop = y; }

  window.__ytmProbe = {
    enumerate: enumerate, elContrast: elContrast, activeState: activeState,
    scrollInfo: scrollInfo, scrollTo: scrollTo, report: function () { return window.__ytmReport ? window.__ytmReport() : null; },
  };
})();
`;
