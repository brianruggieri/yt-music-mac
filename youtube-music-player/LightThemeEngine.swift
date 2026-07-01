//
//  LightThemeEngine.swift
//  youtube-music-player
//
//  music.youtube.com ships no light theme — it hardcodes `dark=true` and only
//  dark styling. Rather than bundle a fragile ~2,800-line community stylesheet of
//  hardcoded selectors, this engine learns YT Music's own design tokens at runtime
//  and derives a light palette from them.
//
//  YT Music's colors form a two-layer token graph: ~200 semantic tokens
//  (--ytmusic-background, --ytmusic-text-primary, …) all resolve through ~15
//  concrete primitives (--ytmusic-color-black4 #030303, --ytmusic-color-white1 #fff,
//  the white1-alphaNN scale, the greys). We harvest every *concrete-valued*
//  --ytmusic-* token, flip its lightness (hue/saturation preserved, so brand red
//  stays red), and re-inject the inverted values scoped to html[data-ytm-mode="light"].
//  Because the semantic tokens reference the primitives via var(), overriding the
//  primitives cascades to the whole UI automatically — and any concrete color token
//  Google adds later gets inverted too, so it self-heals across UI changes.
//
//  The handful of tokens where pure inversion misreads a color's *role* (mid-grey
//  foregrounds, borders) live in OVERRIDES as declarative data, keeping the engine
//  itself free of per-element special cases.

enum LightThemeEngine {
    static let script = #"""
    (function () {
        'use strict';
        if (window.__ytmLightEngine) return;
        window.__ytmLightEngine = true;

        // ---------- color parsing ----------
        function parse(v) {
            if (!v) return null;
            v = v.trim();
            let m = v.match(/^#([0-9a-fA-F]{3,8})$/);
            if (m) {
                let h = m[1];
                if (h.length === 3 || h.length === 4) h = h.split('').map(c => c + c).join('');
                const a = h.length >= 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
                return { r: parseInt(h.slice(0, 2), 16), g: parseInt(h.slice(2, 4), 16), b: parseInt(h.slice(4, 6), 16), a: a };
            }
            m = v.match(/^rgba?\(([^)]+)\)$/i);
            if (m) {
                const p = m[1].split(',').map(s => parseFloat(s));
                if (p.length < 3 || p.slice(0, 3).some(n => isNaN(n))) return null;
                return { r: p[0], g: p[1], b: p[2], a: p[3] === undefined ? 1 : p[3] };
            }
            return null;
        }

        // Resolve ANY css color form (keywords like `white`, hsl(), etc.) to rgba
        // via a cached hidden probe — regex parse() alone misses keyword colors,
        // which is exactly how some link text slips through. var()/inherit yield
        // nothing here and are skipped (correct — those follow the token cascade).
        // Lazily created on first use — at engine-injection time the document root
        // may not exist yet (some injectors run before <html>), so we don't touch
        // the DOM until a color actually needs resolving.
        let probeEl = null;
        function probe() {
            if (!probeEl) {
                probeEl = document.createElement('span');
                probeEl.style.display = 'none';
                (document.documentElement || document.head || document.body || document).appendChild(probeEl);
            }
            return probeEl;
        }
        const colorCache = {};
        function toRGB(value) {
            if (!value) return null;
            if (value in colorCache) return colorCache[value];
            let out = parse(value);
            if (!out && value.indexOf('var(') < 0 && value !== 'inherit' && value !== 'currentcolor' && value !== 'currentColor') {
                const p = probe();
                p.style.color = '';
                p.style.color = value;
                if (p.style.color) out = parse(getComputedStyle(p).color);
            }
            colorCache[value] = out;
            return out;
        }

        function rgbToHsl(r, g, b) {
            r /= 255; g /= 255; b /= 255;
            const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
            let h = 0, s = 0, l = (mx + mn) / 2;
            if (mx !== mn) {
                const d = mx - mn;
                s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
                if (mx === r) h = (g - b) / d + (g < b ? 6 : 0);
                else if (mx === g) h = (b - r) / d + 2;
                else h = (r - g) / d + 4;
                h /= 6;
            }
            return { h: h, s: s, l: l };
        }

        function hslToRgb(h, s, l) {
            if (s === 0) { const v = Math.round(l * 255); return { r: v, g: v, b: v }; }
            const hue = (p, q, t) => {
                if (t < 0) t += 1; if (t > 1) t -= 1;
                if (t < 1 / 6) return p + (q - p) * 6 * t;
                if (t < 1 / 2) return q;
                if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
                return p;
            };
            const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
            const p = 2 * l - q;
            return {
                r: Math.round(hue(p, q, h + 1 / 3) * 255),
                g: Math.round(hue(p, q, h) * 255),
                b: Math.round(hue(p, q, h - 1 / 3) * 255)
            };
        }

        // Flip lightness, keep hue+saturation (brand red stays red). Soften the
        // bright end so backgrounds land on a soft off-white, not glaring #fff.
        function invert(value, keepAlpha) {
            const c = toRGB(value);
            if (!c) return null;
            const hsl = rgbToHsl(c.r, c.g, c.b);
            let nl = 1 - hsl.l;
            if (nl > 0.90) nl = 0.90 + (nl - 0.90) * 0.6;   // ~0.96 ceiling
            const o = hslToRgb(hsl.h, hsl.s, nl);
            // Damp only HEAVY translucent films (hover/active highlights): a white-alpha
            // 0.7 film straight-inverts to a black 0.7 slab over light — too heavy. Thin
            // it by how dark it became so highlights stay subtle. Faint overlays (dividers
            // ~alpha 0.1) are left untouched so borders/separators don't vanish.
            // keepAlpha bypasses this entirely for TEXT: a white-alpha 0.7 secondary label
            // must stay ~0.7 (→ a dark grey), not get thinned to near-invisible — damping
            // is right for background films, fatal for text. This is the cascade-level fix
            // that keeps secondary text dark everywhere without leaning on the audit.
            let a = c.a;
            if (!keepAlpha && a < 1 && a > 0.3) a = Math.round(a * (0.12 + 0.88 * nl) * 1000) / 1000;
            return a < 1 ? 'rgba(' + o.r + ', ' + o.g + ', ' + o.b + ', ' + a + ')'
                         : 'rgb(' + o.r + ', ' + o.g + ', ' + o.b + ')';
        }

        // Invert every color literal inside an arbitrary value (gradients, multi-stop
        // borders, box-shadows) while leaving structure/stops/positions intact. This
        // is what flips the immersive header gradient and the scroll nav-bar fill.
        function invertColorsInString(value) {
            return value.replace(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)/g, m => invert(m) || m);
        }
        function hasGradient(v) { return v.indexOf('gradient(') >= 0; }
        function hasColor(v) { return /#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(/.test(v); }
        // Border / outline / SVG-fill style props: flip light-grey edges dark so
        // dividers, separators and icon strokes stay visible on a light surface.
        const EDGE_PROPS = {
            'border-color': 1, 'border-top-color': 1, 'border-right-color': 1, 'border-bottom-color': 1,
            'border-left-color': 1, 'outline-color': 1, 'text-decoration-color': 1, 'column-rule-color': 1,
            'caret-color': 1, 'fill': 1, 'stroke': 1
        };

        // Stragglers: tokens whose role pure inversion misreads. Declarative data,
        // tuned by measuring contrast in the running app. A value of null means
        // "leave YT's dark value untouched in light mode".
        const OVERRIDES = {
            // filled in by the straggler loop
        };

        // YT's immersive theming sets these SEMANTIC background tokens inline on the
        // root from page content (a dark, content-derived colour), which bypasses our
        // primitive overrides. Re-point each to its primitive and emit with !important
        // so the inline (non-important) value loses and backgrounds stay light.
        const FORCE = {
            '--ytmusic-background': 'var(--ytmusic-general-background-c)',
            '--ytmusic-general-background-a': 'var(--ytmusic-color-black2)',
            '--ytmusic-general-background-b': 'var(--ytmusic-color-black2)',
            '--ytmusic-general-background-c': 'var(--ytmusic-color-black4)',
            '--ytmusic-nav-bar': 'var(--ytmusic-general-background-c)',
            '--ytmusic-player-page-background': 'var(--ytmusic-general-background-c)',
            '--ytmusic-brand-background-solid': 'var(--ytmusic-color-black1)'
        };

        // Surfaces YT paints with a hardcoded literal color instead of a token.
        // We re-point them at the derived token so they track the learned palette
        // — still no hardcoded colors here, just rerouting through what we learned.
        // Deliberately NOT fixed (verified correct in light mode): #scrim and queue
        // hover are translucent-black overlays that should stay dark; the video/art
        // region is a neutral letterbox.
        const SURFACE_FIXES = [
            // Song/Video player toggle (ytmusic-av-toggle). Mirror dark mode's own logic:
            // there the track is dark (#212121) and YT lifts the SELECTED segment onto a
            // lighter white-alpha fill (`[playback-mode] .{song,video}-button`), while the
            // unselected segment stays the track colour. Inverting that for light: the track
            // and unselected segment are the same recessed grey (already produced by the
            // token inversion, ~#dedede), and the selected segment becomes a RAISED WHITE
            // pill (+ soft shadow). We key off YT's OWN selection signal — the host
            // `playback-mode` attribute (ATV→song, OMV→video) — and repeat its `.ytmusic-av-toggle`
            // class so we out-specify the inverted `.song-button.ytmusic-av-toggle` grey rule.
            // The earlier fix painted track AND both buttons one flat grey, which is exactly
            // why neither side read as selected.
            // OWNERSHIP BOUNDARY: once the visualizer injects its 3rd button it adds
            // `.milkviz-styled` to .av-toggle and fully owns the control's look + selection
            // (track, buttons, the selected pill via its own .milkviz-sel class) in BOTH
            // themes. These engine rules paint selection off YT's `playback-mode`, which the
            // overlay never changes — so without the :not() guard the two systems fight (Video
            // stays "selected" next to the Visualizer, and we'd need counter-observers). Gate
            // them off the milkviz-owned toggle; they still theme the plain 2-button control
            // before injection / when the visualizer is unsupported.
            ['.av-toggle:not(.milkviz-styled)', 'background-color: var(--ytmusic-color-black1)'],
            ['ytmusic-av-toggle[playback-mode="ATV_PREFERRED"] .av-toggle:not(.milkviz-styled) .song-button.ytmusic-av-toggle, ytmusic-av-toggle[playback-mode="OMV_PREFERRED"] .av-toggle:not(.milkviz-styled) .video-button.ytmusic-av-toggle',
                'background-color: rgb(255, 255, 255); box-shadow: 0 1px 2px rgba(0,0,0,0.2)'],
            // Modal scrim (tp-yt-iron-overlay-backdrop — the dimming layer behind every
            // dialog: edit-playlist, add-to-playlist, etc.). YT colours it from an inverted
            // iron/paper token, so in light mode it flips to near-WHITE — clicking a dialog
            // open then WASHES the page out (desaturated, low-contrast) instead of darkening
            // it, and the white dialog on a washed-white page is nearly invisible. A modal
            // backdrop must always be a DARK translucent scrim (Material and macOS both dim
            // dark, light theme or not). Pin it dark (YT keeps its own ~0.3 opacity) so the
            // page dims properly and the dialog on top pops.
            ['tp-yt-iron-overlay-backdrop', 'background-color: #000000'],
            // Edit-thumbnail / image-cropper dialog. Its tp-yt-paper-dialog is transparent
            // (alpha 0) and NO child paints a surface — invisible over dark mode's dark page,
            // but in light mode the cropper canvas, title and Cancel/Done float over the
            // dimmed page with no card behind them: reads as a huge unbounded image with the
            // track list bleeding through (the "layering" mess). Give just this dialog (scoped
            // via :has) a real opaque light card. NOTHING else — the dialog is a fixed 632x741
            // (it never scales with the viewport), so size caps are pointless, and an
            // overflow/scroll cap would shift the canvas under the JS-positioned crop handles
            // and misalign them. Background only.
            ['tp-yt-paper-dialog:has(yt-image-editor-renderer)',
                'background-color: rgb(255, 255, 255)'],
            // Playlist "description" popup (#13): same transparent-dialog problem — a
            // tp-yt-paper-dialog wrapping ytmusic-dismissable-dialog-renderer whose surface
            // (--paper-dialog-background-color) is alpha-0 in light, so the track list bleeds
            // through. Give it an opaque card (text/✕ are already dark).
            ['tp-yt-paper-dialog:has(ytmusic-dismissable-dialog-renderer)',
                'background-color: rgb(255, 255, 255); box-shadow: 0 1px 2px rgba(0,0,0,0.2)'],
            // …and its close ✕ glyph: YT draws it white (for the dark fallback surface), so on
            // the white card above it vanished. Pin the dialog's icons dark — including the
            // svg <path> (its white comes from the path's own fill), so the ✕ shows.
            ['ytmusic-dismissable-dialog-renderer yt-icon, ytmusic-dismissable-dialog-renderer yt-icon-button, ytmusic-dismissable-dialog-renderer svg, ytmusic-dismissable-dialog-renderer svg path',
                'color: rgb(17, 17, 17); fill: rgb(17, 17, 17)'],
            // Download toast (#15): tp-yt-paper-toast is an INVERSE-surface component — its
            // surface stays light-grey in BOTH themes, but the engine's token inversion flips
            // its dark text to near-white → invisible on the light snackbar (~1:1). Pin the
            // text/icons dark (what dark mode already renders); leave the surface + blue "View".
            ['tp-yt-paper-toast, tp-yt-paper-toast yt-formatted-string, ytmusic-notification-action-renderer #text, ytmusic-notification-action-renderer yt-icon, tp-yt-paper-toast svg',
                'color: rgb(17, 17, 17); fill: rgb(17, 17, 17)'],
            // The immersive backdrop / scrolled nav bar fill is one element YT colors
            // inline from page content (a dark value the cascade can't reach). Pin it
            // to the light surface so both the header and the scroll bar read light.
            ['#nav-bar-background', 'background: var(--ytmusic-background)'],
            // The sidebar wrapper uses --ytmusic-background too; on immersive pages YT
            // poisons that token dark, so pin the strip to a fixed light surface.
            ['#guide-wrapper', 'background-color: rgb(243, 243, 243)'],
            // The account menu (avatar dropdown) is a ytd-* popup themed off the
            // --yt-sys-color-baseline-* Material chain (resolves dark). Labels/icons we
            // can flip with a stylesheet rule; the surface is pinned inline (pinMenu)
            // because the Material `background: var()` rule beats our scoped !important.
            ['.ytmusicMultiPageMenuRendererHost yt-formatted-string, .ytmusicMultiPageMenuRendererHost .yt-core-attributed-string, .ytmusicMultiPageMenuRendererHost yt-icon, .ytmusicMultiPageMenuRendererHost #label', 'color: rgb(20, 20, 20)'],
            // Track-row context menu (ytmusic-menu-popup-renderer): its service-item icons
            // are svgs YT fills white through the Material var chain, which the token
            // inversion can't reach — white-on-#DEDEDE is 1.35:1 (fails WCAG 1.4.11). Pin
            // them dark, the same way the account menu's icons are handled just above.
            ['ytmusic-menu-popup-renderer yt-icon, ytmusic-menu-popup-renderer svg', 'color: rgb(20, 20, 20); fill: rgb(20, 20, 20)'],
            // Default for every play button: keep the triangle dark so the glyph stays
            // visible on a light circle (YT's knockout reads as near-white on near-white
            // otherwise).
            ['ytmusic-play-button-renderer yt-icon, ytmusic-play-button-renderer svg', 'color: rgb(3, 3, 3); fill: rgb(3, 3, 3)'],
            // EXCEPTION — play buttons overlaid on album/video art (the thumbnail-overlay
            // renderer: track-row hover buttons, playlist/album card buttons). These sit on
            // imagery behind a dark hover scrim, exactly like dark mode, where YT keeps the
            // triangle WHITE. The blanket dark rule above would paint them near-black on a
            // dark scrim (invisible) — so re-whiten them here (more specific → wins).
            ['ytmusic-item-thumbnail-overlay-renderer ytmusic-play-button-renderer yt-icon, ytmusic-item-thumbnail-overlay-renderer ytmusic-play-button-renderer svg', 'color: #ffffff; fill: #ffffff'],
            // Brand red, white triangle — ONLY the standalone circular play affordances:
            // the page header CTA and the left-bar (guide) playlist buttons. These are
            // real circular buttons, so a #f03 fill reads as a proper brand play button.
            // More specific than the knockout above, so the white glyph wins there.
            ['ytmusic-responsive-header-renderer ytmusic-play-button-renderer, ytmusic-detail-header-renderer ytmusic-play-button-renderer, ytmusic-guide-entry-renderer ytmusic-play-button-renderer',
                'background-color: #ff0033'],
            ['ytmusic-responsive-header-renderer ytmusic-play-button-renderer yt-icon, ytmusic-responsive-header-renderer ytmusic-play-button-renderer svg, ytmusic-detail-header-renderer ytmusic-play-button-renderer yt-icon, ytmusic-detail-header-renderer ytmusic-play-button-renderer svg, ytmusic-guide-entry-renderer ytmusic-play-button-renderer yt-icon, ytmusic-guide-entry-renderer ytmusic-play-button-renderer svg',
                'color: #ffffff; fill: #ffffff'],
        ];

        // Light-mode polish (tunable). The page's own top gradient is handled by the
        // generic gradient inversion (it scrolls with content like the real page — we
        // just flip its colours); no custom page-background gradient here. These only
        // add gentle depth so surfaces read as layered, not washed:
        //  - subtle elevation shadows so cards/thumbnails pop off the page
        //  - a crisper hairline divider tone than a raw invert gives
        const ENHANCE = [
            ['html, body', 'background-color: var(--ytmusic-background)'],
            // No elevation shadow on thumbnails — YT's own (dark) UI never shadows cover
            // art, and our added shadow only created problems on light: the renderer's
            // border-radius (8px) didn't match the image's native radius (12px), so the
            // shadow traced a squarer box than the image and left a gap at the corners.
            // The artwork already reads fine on the light surface (it's imagery, not a
            // flat card), so we match dark mode and draw nothing. (Genuinely low-contrast
            // card surfaces still get a hairline via auditSurfaces() — that's unaffected.)
            ['ytmusic-carousel-shelf-renderer, ytmusic-shelf-renderer',
                'border-color: rgba(0,0,0,0.08)'],
            // Unselected category chips: defined outlined pills so they read as
            // buttons (a subtle fill + visible hairline border over YT's rounded
            // shape, with the inverted dark label). The selected chip keeps YT's
            // filled style, so selected vs unselected stays clear.
            ['ytmusic-chip-cloud-chip-renderer:not([is-selected]) a.yt-simple-endpoint',
                'background-color: rgba(0,0,0,0.04); border: 1px solid rgba(0,0,0,0.22)'],
            // Explore destination buttons (New releases / Charts / …) and the mood/genre
            // buttons: their surface is a translucent WHITE (rgba(255,255,255,0.15)) that
            // the inverter leaves alone, so on the light page it's invisible — the button
            // has no boundary (genre buttons show only their coloured left edge floating).
            // Give them a defined card: a subtle fill + a 1px inset hairline RING. The ring
            // is a box-shadow, not a border, so it never fights the genre colour's 6px
            // border-left, which we keep as YT's category cue.
            ['button.ytmusic-navigation-button-renderer',
                'background-color: rgba(0,0,0,0.04); box-shadow: inset 0 0 0 1px rgba(0,0,0,0.16)'],
            // YT "tonal" buttons — the guide's "New playlist" button and tonal buttons
            // elsewhere — fill themselves with a translucent WHITE (rgba(255,255,255,0.1))
            // that's invisible on the light page, so the button loses all boundary. Give the
            // whole tonal class the SAME defined card the navigation buttons get: a subtle
            // fill + a 1px inset hairline ring. Global by design (matches every tonal button),
            // not a one-off — tonal buttons are *meant* to read as a filled surface.
            ['button.ytSpecButtonShapeNextTonal',
                'background-color: rgba(0,0,0,0.05); box-shadow: inset 0 0 0 1px rgba(0,0,0,0.16)'],
            // --- QA batch (2026-06-29) ---
            // Rounded hover (#3/#4/#7): on two-row cards the hover ripple (tp-yt-paper-ripple)
            // and dark scrim (ytmusic-background-overlay-renderer) are SIBLINGS of the
            // 8px-rounded thumbnail, so its overflow:hidden never clips them — they're clipped
            // only by a.image-wrapper, which is border-radius:0, leaving square dark corners on
            // the light page. The wrapper is already overflow:hidden, so rounding IT clips the
            // image, ripple and scrim together. (Artist tiles are circular — verify they don't
            // square; if so, add a 50% variant for those.)
            ['ytmusic-two-row-item-renderer a.image-wrapper', 'border-radius: 8px'],
            // Explore + genre buttons had no hover (#10/#11): YT's own hover goes solid #212121,
            // invisible on the light surface. Deeper translucent-dark fill on hover.
            ['button.ytmusic-navigation-button-renderer:hover', 'background-color: rgba(0,0,0,0.24)'],
            // Genre/mood tiles (#11): drop the inset hairline ring, keeping ONLY YT's coloured
            // left bar (matches the app's left-bar selection cue). Scoped to tiles carrying the
            // inline stripe var, so the four Explore destination buttons keep their ring.
            ['ytmusic-navigation-button-renderer[style*="left-stripe-color"] button.ytmusic-navigation-button-renderer',
                'box-shadow: none'],
            // Byline separators (#1): the "•"/"&" inherit YT's translucent secondary token,
            // which inverts (alpha-damped) to ~8% black = invisible. The text-rescue can't reach
            // them (the glyph span is <8px wide; .flex-column::before is a pseudo-element), so
            // recolour them to match the rescued byline text (rgb 82,82,82). Recolouring the
            // subtitle/complex-string parent is safe — the real text spans carry their own
            // inline !important, so only the inheriting separators change.
            ['ytmusic-responsive-list-item-renderer .secondary-flex-columns .flex-column::before',
                'color: rgb(82,82,82)'],
            // Same byline-separator damping shows on Home/Explore carousel cards
            // (ytmusic-two-row-item-renderer) and card shelves — their subtitle "•"/"&"
            // glyphs inherit the same translucent token while the artist text spans get
            // rescued. The original rule only reached list-item rows, so card bylines kept
            // the faded separators; extend the same recolour to the card subtitle parents.
            ['ytmusic-responsive-header-renderer .subtitle, ytmusic-responsive-header-renderer .second-subtitle, ytmusic-responsive-list-item-renderer yt-formatted-string.complex-string, ytmusic-two-row-item-renderer yt-formatted-string.subtitle, ytmusic-card-shelf-renderer yt-formatted-string.subtitle',
                'color: rgb(82,82,82)'],
            // Now-playing bar byline ("Artist • Album • Year"): same damped "•" separators.
            // The artist/album are links carrying their own colour, so recolouring the byline
            // parent only catches the inheriting separator glyphs — not the red title (a
            // separate .title element) above it.
            ['.content-info-wrapper.ytmusic-player-bar yt-formatted-string.byline.ytmusic-player-bar',
                'color: rgb(82,82,82)'],
            // Multi-select checkboxes (#14): same damped ~8% token on the hollow-square svg;
            // the icon-rescue skips it (fill alpha < 0.4 gate). Give the outline a visible
            // weight, and a near-black filled box when checked.
            ['yt-checkbox-renderer, yt-checkbox-renderer yt-icon, yt-checkbox-renderer svg',
                'color: rgba(0,0,0,0.55); fill: rgba(0,0,0,0.55)'],
            // "Video not available" (and sibling) snackbars: yt-notification-action-renderer
            // has no light-mode surface of its own, so the token inversion left it an all-black
            // box with invisible text in the bottom-left. Snackbars stay DARK by convention
            // (like the modal scrim), so pin a readable dark pill with white text rather than
            // inverting it to light. Scope text white so the contrast audit leaves it alone.
            ['yt-notification-action-renderer, ytmusic-notification-action-renderer',
                'background-color: rgb(32,33,36); border-radius: 8px'],
            ['yt-notification-action-renderer yt-formatted-string, ytmusic-notification-action-renderer yt-formatted-string, yt-notification-action-renderer #text, yt-notification-action-renderer #sub-text',
                'color: rgb(255,255,255)'],
            ['yt-checkbox-renderer[aria-checked="true"] yt-icon, yt-checkbox-renderer[aria-checked="true"] svg',
                'color: rgb(13,13,13); fill: rgb(13,13,13)'],
        ];

        // Brand red, used on purpose in a FEW active/hover places so it keeps meaning
        // (DESIGN.md "Where red shows up"). The split-by-role rule: red TEXT and thin
        // lines use Red Ink #cc0029 (AA-safe, ~5.3:1 on the #f3f3f3 surface — pure red
        // is only ~3.6:1 and fails 4.5:1 for text); red FILLS/markers use brand #ff0033.
        const RED = [
            // Active/playing — the now-playing track title in the player bar reads as
            // "this is live". It's text, so Red Ink. YT's own title rule is
            // `.content-info-wrapper.ytmusic-player-bar .title.ytmusic-player-bar` (which
            // the engine inverts to black !important), so we mirror it and add one more
            // `.title` to win on specificity — equal-specificity would lose, since the
            // engine's selector-fixes are emitted after this block.
            ['.content-info-wrapper.ytmusic-player-bar .title.title.ytmusic-player-bar', 'color: #cc0029'],
            // Active/playing — a red left marker on the selected sidebar (guide) item.
            // The label text stays near-black for legibility; red is the marker, not the
            // word. The app uses the guide drawer (no pivot bar); active entry carries
            // the empty `active` attribute. 6px to match YT's own thicker coloured-left-edge
            // convention (the mood/genre buttons use a 6px border-left) for a consistent
            // "this category/section" identity across the app.
            ['ytmusic-guide-entry-renderer[active] tp-yt-paper-item', 'box-shadow: inset 6px 0 0 0 #ff0033'],
            // Hover/active accent — the selected player-page tab gets a Red Ink underline.
            ['tp-yt-paper-tab.iron-selected', 'border-bottom: 2px solid #cc0029'],
            // Hover/active accent — content link hover reads Red Ink (scoped to list/shelf
            // links so it threads red through navigation without repainting every anchor).
            ['ytmusic-responsive-list-item-renderer a.yt-simple-endpoint:hover, ytmusic-shelf-renderer a.yt-simple-endpoint:hover, ytmusic-carousel-shelf-renderer a.yt-simple-endpoint:hover',
                'color: #cc0029'],
        ];

        // Keyboard focus rings — WCAG 2.4.7 (Focus Visible). YT's focus relies on
        // faint background tints that all but vanish on a light surface, so keyboard
        // users lose the caret. A single high-contrast ring (blue, ~4.5:1 on white,
        // deliberately NOT the brand red so it never reads as "selected/playing"),
        // only on :focus-visible so mouse clicks don't draw rings.
        const FOCUS = [
            ['a:focus-visible, button:focus-visible, [tabindex]:focus-visible, ' +
             'tp-yt-paper-icon-button:focus-visible, tp-yt-paper-item:focus-visible, ' +
             'ytmusic-pivot-bar-item-renderer:focus-visible, ' +
             'ytmusic-responsive-list-item-renderer:focus-visible, ' +
             'ytmusic-chip-cloud-chip-renderer a:focus-visible, ' +
             // NOT inputs/selects: text fields signal focus with their native Material
             // underline (the line turns the accent colour) — a surrounding box ring is the
             // wrong convention and double-rings the search pill (which keeps the rule below).
             'yt-button-shape:focus-visible',
             'outline: 2px solid #1a73e8; outline-offset: 2px; border-radius: 6px'],
            ['ytmusic-search-box:focus-within',
             'outline: 2px solid #1a73e8; outline-offset: 1px; border-radius: 8px'],
            // Text inputs/selects: suppress BOTH our ring (dropped above) AND the browser's
            // default UA focus outline, so focus shows only via the native Material underline
            // (dialog title/description/privacy) or the search pill's :focus-within ring above.
            // Those are the visible indicators, so this still satisfies WCAG 2.4.7. EXCLUDE the
            // input types whose ONLY focus cue is the outline (checkbox/radio/range/file) — they
            // have no underline to fall back on, so they keep their native ring.
            ['input:not([type="checkbox"]):not([type="radio"]):not([type="range"]):not([type="file"]):focus, input:not([type="checkbox"]):not([type="radio"]):not([type="range"]):not([type="file"]):focus-visible',
                'outline: none'],
        ];

        // Grayscale + light? Used to gate literal text-color inversion: only flip
        // hardcoded white/light-grey text (the washout cases), never colored text
        // (badges, brand), so there's nothing to misjudge.
        // Theme custom-property families to invert: YT's own (--yt*) AND Polymer's
        // (--paper-*/--iron-*), which colour every tp-yt-paper-* component — dialogs,
        // context menus, dropdowns, sliders, spinners, toasts, tooltips.
        function isThemeToken(p) { return p.indexOf('--yt') === 0 || p.indexOf('--paper') === 0 || p.indexOf('--iron') === 0; }
        function isGray(c) { return c && Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b) <= 16; }
        function lumOf(c) { return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255; }
        function isLightGray(c) { return c && c.a !== 0 && isGray(c) && lumOf(c) >= 0.5; }
        // Opaque dark surface — invert it. Opacity gate is the discriminator: a
        // translucent dark fill is a scrim/overlay (meant to stay dark), an opaque
        // one is a real surface whose now-dark-inverted text would otherwise vanish.
        function isDarkOpaqueGray(c) { return c && c.a >= 1 && isGray(c) && lumOf(c) < 0.5; }

        // Prefix each comma-separated part of a selector with our mode scope,
        // respecting parens so :is()/:where() lists aren't split mid-group.
        // Split a selector list on TOP-LEVEL commas only (parens preserved so :is()/:where()
        // groups aren't split mid-list). Shared by scope() and the av-toggle ownership filter.
        function splitSelectorParts(sel) {
            const parts = []; let depth = 0, cur = '';
            for (const ch of sel) {
                if (ch === '(') depth++;
                else if (ch === ')') depth--;
                if (ch === ',' && depth === 0) { parts.push(cur); cur = ''; } else cur += ch;
            }
            if (cur.trim()) parts.push(cur);
            return parts;
        }
        function scope(sel) {
            return splitSelectorParts(sel).map(p => {
                p = p.trim();
                // A part rooted at <html> (e.g. "html", "html, body") must MERGE the mode
                // attribute onto html, not become a descendant of it (html has no html
                // child). Without this, "html, body" scoped only on the first selector left
                // "body" global — leaking light-mode rules into native dark.
                if (/^html(\b|[.#:[])/.test(p)) return p.replace(/^html/, 'html[data-ytm-mode="light"]');
                return 'html[data-ytm-mode="light"] ' + p;
            }).join(', ');
        }

        // ---------- scan YT's stylesheets ----------
        // YT sets text/link color three ways; we mirror each at its own cascade origin:
        //   1. root design tokens (html[dark]{--yt*: ...})        -> invert globally, cascades
        //   2. component-scoped token redefinitions (sel{--yt-endpoint-color:#fff}) -> invert per selector
        //   3. direct literal text color (sel{color:#fff})        -> invert per selector
        // (2) and (3) only fire for light-grey literals, so colored text/brand is never touched.
        function scan() {
            const tokens = {};
            const selFixes = {};   // scoped selector -> ["prop: inverted", ...]
            for (const sheet of document.styleSheets) {
                // Never scan our OWN output sheet. Its rules are already scoped +
                // inverted; re-scanning re-scopes them (a new html[...] prefix → a new
                // unique key every tick), so selFixes — and the emitted <style> — grow
                // without bound. That made build() re-run and replace the whole stylesheet
                // every tick (a full recalc/repaint → visible icon flicker, plus a slow
                // memory leak). Skipping it lets the counts settle and build() go quiet.
                if (sheet.ownerNode && sheet.ownerNode.id === 'ytm-light-theme') continue;
                let rules;
                try { rules = sheet.cssRules; } catch (e) { continue; }
                if (!rules) continue;
                for (const rule of rules) {
                    if (!rule.style) continue;
                    for (const prop of rule.style) {
                        // Whole YouTube token universe: --ytmusic-*, --yt-endpoint-*,
                        // --yt-sys-color-*, --yt-spec-*. Links etc. live in --yt-*.
                        if (!isThemeToken(prop) || prop in tokens) continue;
                        const val = rule.style.getPropertyValue(prop).trim();
                        // Concrete colors AND gradient-valued tokens (overlay/immersive gradients).
                        if (toRGB(val) || (hasGradient(val) && hasColor(val))) tokens[prop] = val;
                    }
                    if (!rule.selectorText) continue;
                    const decls = [];
                    for (const prop of rule.style) {
                        const v = rule.style.getPropertyValue(prop).trim();
                        if (!v) continue;
                        const c = toRGB(v);
                        if (prop === 'background-image') {
                            // gradients (the immersive header / scroll nav-bar fill)
                            if (hasGradient(v) && hasColor(v)) decls.push('background-image: ' + invertColorsInString(v));
                        } else if (prop === 'background-color' || prop === 'background') {
                            if (c && isDarkOpaqueGray(c)) decls.push(prop + ': ' + invert(v));
                            // Translucent LIGHT films are YT's hover/active highlights (chips,
                            // pills, rows, icon buttons all "light up" via rgba(255,255,255,.1-.2)).
                            // Left as-is they're invisible on the light page — every hover/press
                            // does nothing. Flip them to the matching dark-alpha so the SAME
                            // feedback reads on light. invert() damps heavy films; translucent
                            // BLACK scrims are dark (isLightGray false) → untouched, stay dark.
                            // …but NOT touch-feedback / ripple press layers: inverting their
                            // translucent-white fill to translucent-dark paints a dark disc
                            // behind icon-button glyphs (e.g. the ⋮ menu), and a dark glyph on
                            // that disc loses all contrast. Leave those subtle.
                            else if (c && c.a > 0 && c.a < 1 && isLightGray(c) && !/touch-feedback|ripple/i.test(rule.selectorText || '')) decls.push(prop + ': ' + invert(v));
                            else if (hasGradient(v) && hasColor(v)) decls.push(prop + ': ' + invertColorsInString(v));
                        } else if (isThemeToken(prop)) {
                            // Local --yt*/--paper* token redefinition (e.g. a popup setting
                            // --yt-sys-color-...-background: #282828 on its own host). Flip
                            // ALL of them, light OR dark — lightness inversion preserves hue,
                            // so this lights popup surfaces and their text without touching brand.
                            if (c) decls.push(prop + ': ' + invert(v));
                            else if (hasGradient(v) && hasColor(v)) decls.push(prop + ': ' + invertColorsInString(v));
                        } else if (prop === 'color') {
                            // Direct text colour: only flip washed-out light-grey literals.
                            // keepAlpha: YT's secondary text is translucent white; preserve
                            // the alpha so it inverts to a dark translucent grey (readable),
                            // not a near-invisible one — the cascade-level secondary-text fix.
                            if (c && isLightGray(c)) decls.push('color: ' + invert(v, true));
                        } else if (EDGE_PROPS[prop]) {
                            // dividers / borders / separators / icon strokes
                            if (c) { if (isLightGray(c)) decls.push(prop + ': ' + invert(v)); }
                            else if (hasColor(v)) decls.push(prop + ': ' + invertColorsInString(v));
                        }
                    }
                    if (decls.length) {
                        // OWNERSHIP BOUNDARY: the Song/Video/Visualizer toggle is fully owned by
                        // the visualizer once injected, so don't invert YT's av-toggle highlight
                        // literals — its selected-segment fill is rgba(255,255,255,.1), which this
                        // scanner would flip to a dark pill and re-emit scoped+!important at (0,4,2),
                        // painting whatever YT marks selected (playback-mode stays on Song/Video even
                        // while the overlay is active) and fighting the visualizer's own .milkviz-sel.
                        // Drop only the av-toggle PARTS so unrelated selectors grouped in the same
                        // rule still get their inversion emitted.
                        const kept = splitSelectorParts(rule.selectorText)
                            .filter(function (p) { return !/av-toggle|song-button|video-button/.test(p); });
                        if (!kept.length) continue;
                        const k = scope(kept.join(','));
                        selFixes[k] = (selFixes[k] || []).concat(decls);
                    }
                }
            }
            return { tokens: tokens, selFixes: selFixes };
        }

        let styleEl = null;
        let knownTokens = 0, knownSel = 0;
        function build() {
            const found = scan();
            const names = Object.keys(found.tokens);
            const selN = Object.keys(found.selFixes).length;
            // Rebuild when EITHER tokens or per-selector fixes grow. Menus/dialogs load
            // their (dark) CSS lazily on first open — that adds selector rules, not new
            // tokens, so gating on token count alone left those popups un-inverted (black).
            if (names.length <= knownTokens && selN <= knownSel) return false;
            knownTokens = names.length; knownSel = selN;

            // 1. inverted design tokens (cascades through the whole UI). Single colors
            //    flip via invert(); gradient-valued tokens flip each stop in place.
            //    !important so YT's inline immersive-theming colours can't override us.
            const lines = [];
            for (const name of names) {
                const raw = found.tokens[name];
                const light = name in OVERRIDES ? OVERRIDES[name] : (toRGB(raw) ? invert(raw) : invertColorsInString(raw));
                if (light) lines.push('  ' + name + ': ' + light + ' !important;');
            }
            for (const name in FORCE) lines.push('  ' + name + ': ' + FORCE[name] + ' !important;');
            let css = 'html[data-ytm-mode="light"] {\n' + lines.join('\n') + '\n}\n';

            // 2. surfaces painted with literal colors, rerouted through the tokens,
            //    plus the light-mode depth polish.
            for (const fix of SURFACE_FIXES.concat(ENHANCE, RED, FOCUS)) {
                // scope() each comma-separated part — a naive single prefix would scope only
                // the first selector and let the rest apply globally (dark mode included).
                css += scope(fix[0]) + ' { ' + fix[1].split('; ').map(d => d + ' !important').join('; ') + '; }\n';
            }

            // 3. per-selector light-grey literals (direct color + local --yt* tokens)
            for (const sel in found.selFixes) {
                css += sel + ' { ' + found.selFixes[sel].map(d => d + ' !important').join('; ') + '; }\n';
            }

            if (!styleEl) {
                styleEl = document.createElement('style');
                styleEl.id = 'ytm-light-theme';
                document.documentElement.appendChild(styleEl);   // append last so we win on equal specificity
            }
            styleEl.textContent = css;
            return true;   // rebuilt: new styled content arrived (re-arms the audit cadence)
        }

        // ---------- WCAG contrast helpers ----------
        function relLum(c) {
            const f = [c.r, c.g, c.b].map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
            return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2];
        }
        function ratio(l1, l2) { return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05); }

        // AA enforcer: inversion gets washed-out text close to 4.5:1 but mid-grey
        // secondary/caption text can land just short. Binary-search the largest
        // lightness (closest to the original, so we disturb the design the least)
        // that still clears `target` against the measured background — hue+sat kept.
        // On a light surface we only ever darken (search [0, l]).
        function enforceLightness(fg, bgL, target) {
            const hsl = rgbToHsl(fg.r, fg.g, fg.b);
            let lo = 0, hi = hsl.l, best = null;
            for (let i = 0; i < 14; i++) {
                const mid = (lo + hi) / 2;
                const c = hslToRgb(hsl.h, hsl.s, mid);
                if (ratio(relLum(c), bgL) >= target) { best = c; lo = mid; } else { hi = mid; }
            }
            return best;
        }

        // Cross shadow boundaries: parentElement is null at a shadow-root edge, so
        // hop to the host via parentNode.host. Lets us find a popup's real surface.
        function up(e) { return e.parentElement || (e.parentNode && e.parentNode.host) || null; }
        function effectiveBg(el) {
            for (let e = el; e; e = up(e)) {
                const c = toRGB(getComputedStyle(e).backgroundColor);
                if (c && c.a >= 1) return { c: c, el: e };   // first fully-opaque ancestor bg
            }
            return { c: toRGB(getComputedStyle(document.body).backgroundColor) || { r: 243, g: 243, b: 243, a: 1 }, el: document.body };
        }

        // Collect text-bearing elements, piercing shadow roots (Polymer popups,
        // dialogs and many YT components live in shadow DOM that querySelectorAll
        // can't see — which is why their washed-out text slipped past the audit).
        function collectText(root, acc) {
            if (!root) return acc;
            const els = root.querySelectorAll('*');
            for (const el of els) {
                for (const n of el.childNodes) {
                    if (n.nodeType === 3 && n.textContent.trim().length > 1) { acc.push(el); break; }
                }
                if (el.shadowRoot) collectText(el.shadowRoot, acc);
            }
            return acc;
        }

        // ---------- runtime self-audit (#1) + graceful degradation (#2) ----------
        // The declarative sheet handles the bulk; this catches the long tail the
        // cascade can't reach — inline styles and JS-set colors — by inverting
        // washed-out text in place, and tracks a coverage score. If coverage
        // collapses (a Google redesign the engine can't follow), we fall back to
        // native dark rather than show a half-broken light UI.
        const AA = 4.5;                  // WCAG AA contrast for normal text (failure threshold)
        const READABLE = 7;              // clamp target when we DO darken: aim past the bare
                                         // floor to match YT's own #555 secondary (~6.5:1),
                                         // so fixed text reads comfortably dark, not just "legal"
        const fixedEls = new Set();
        let degraded = false;
        let auditCount = 0, lowStreak = 0;   // hysteresis so transient load states don't trip #2
        let stableAudits = 0, auditTick = 0; // adaptive backoff: consecutive clean audits, and a tick counter

        const bgFixedEls = new Set();
        const surfFixedEls = new Set();
        const iconFixedEls = new Set();
        function clearFixes() {
            for (const el of fixedEls) { el.style.removeProperty('color'); el.removeAttribute('data-ytm-fixed'); }
            for (const el of bgFixedEls) { el.style.removeProperty('background-color'); }
            for (const el of surfFixedEls) el.style.removeProperty('border');
            for (const el of iconFixedEls) { el.style.removeProperty('fill'); el.style.removeProperty('color'); }
            fixedEls.clear();
            bgFixedEls.clear();
            surfFixedEls.clear();
            iconFixedEls.clear();
        }

        // pinImmersive / pinMenu overwrite inline styles with !important; on their own
        // they never revert, so toggling back to dark left the immersive header (and a
        // freshly-opened menu) stuck on the light value. Cache each element's original
        // inline value the first time we touch it and restore it on leaving light mode.
        const immFixed = new Map();    // el -> original inline background-image
        const menuFixed = new Set();
        function restorePins() {
            for (const [el, orig] of immFixed) {
                if (orig) el.style.setProperty('background-image', orig); else el.style.removeProperty('background-image');
            }
            immFixed.clear();
            for (const el of menuFixed) el.style.removeProperty('background-color');
            menuFixed.clear();
        }

        // Non-text (UI component) contrast — WCAG 1.4.11. Our text audit can't see
        // this: a card with dark text on a white fill PASSES text contrast, yet the
        // white card on a near-white page is an invisible boundary. A border-radius is
        // the reliable "this is a card/button/pill" signal; when such a surface is too
        // close in luminance to the surface behind it, give it a hairline border.
        function auditSurfaces() {
            if (degraded || document.documentElement.getAttribute('data-ytm-mode') !== 'light') return;
            for (const el of document.querySelectorAll('*')) {
                if (surfFixedEls.has(el)) continue;
                const cls = typeof el.className === 'string' ? el.className : '';
                // Skip ripple/feedback/overlay fills — they're decorative layers inside
                // a control, not the control's own surface.
                if (/TouchFeedback|ripple|overlay|-overlay/i.test(cls)) continue;
                // The Song/Video/Visualizer toggle is owned by the visualizer once injected;
                // it styles its own track/buttons in both themes. The auto-border audit used
                // to stamp inline hairlines on its pill buttons, which the visualizer then had
                // to chase with a counter-observer — skip the whole control here instead.
                if (el.closest('ytmusic-av-toggle') || el.closest('#milkviz-canvas-host')) continue;
                const st = getComputedStyle(el);
                if (st.position === 'absolute' || st.position === 'fixed') continue;   // overlays, not surfaces
                if ((parseFloat(st.borderTopLeftRadius) || 0) < 4) continue;     // not card-like
                const bg = toRGB(st.backgroundColor);
                if (!bg || bg.a < 1) continue;                                    // needs its own opaque fill
                const bgL = relLum(bg);
                if (bgL < 0.6) continue;                                          // only the light-on-light cases
                const rect = el.getBoundingClientRect();
                if (rect.width < 48 || rect.height < 22 || rect.width > 1000 || rect.bottom < 0 || rect.top > innerHeight) continue;
                // already has a visible border? leave it.
                if (parseFloat(st.borderTopWidth) > 0) { const bc = toRGB(st.borderTopColor); if (bc && bc.a > 0.06) continue; }
                const parent = up(el);
                if (!parent) continue;
                const pL = relLum(effectiveBg(parent).c);
                // Boundary contrast as a ratio (WCAG 1.4.11 thinks in ratios). A white
                // card on a near-white page is ~1.1:1 — far too subtle; a genuinely
                // distinct surface is >~1.35:1 and left alone.
                if (ratio(bgL, pL) < 1.35) {
                    el.style.setProperty('border', '1px solid rgba(0,0,0,0.12)', 'important');
                    surfFixedEls.add(el);
                }
            }
        }

        function audit() {
            if (degraded || document.documentElement.getAttribute('data-ytm-mode') !== 'light') return 1;
            let total = 0, failing = 0;
            for (const el of collectText(document.body, [])) {
                if (el.closest('ytmusic-av-toggle') || el.closest('#milkviz-canvas-host')) continue;   // visualizer-owned control; engine stands down (see scan())
                const st = getComputedStyle(el);
                if (st.visibility === 'hidden' || st.opacity === '0') continue;
                const rect = el.getBoundingClientRect();
                if (rect.width < 8 || rect.height < 6) continue;
                const fg = toRGB(st.color);
                if (!fg || fg.a === 0) continue;
                const eb = effectiveBg(el);
                let bgL = relLum(eb.c);
                // Composite translucent text over its real background before scoring.
                // YT's secondary text is translucent white; invert() flips it to a
                // near-transparent BLACK (alpha-damped), which renders almost invisible
                // yet would score as solid black if we read the raw rgb — the false-pass
                // that quietly lost artist names / bylines. Blend so contrast reflects
                // what's actually on screen, and so the fix below targets a real color.
                const fgC = fg.a < 1
                    ? { r: Math.round(fg.r * fg.a + eb.c.r * (1 - fg.a)),
                        g: Math.round(fg.g * fg.a + eb.c.g * (1 - fg.a)),
                        b: Math.round(fg.b * fg.a + eb.c.b * (1 - fg.a)) }
                    : fg;
                const fgL = relLum(fgC);
                total++;
                let r = ratio(fgL, bgL);
                if (r < AA) {
                    // On a light surface, ANY failing text (washed-light or faint-grey, opaque
                    // or translucent) gets darkened from its COMPOSITED on-screen colour to a
                    // SOLID grey at the READABLE target — one path, always opaque, so a
                    // translucent fix can't re-introduce the invisibility we just removed.
                    // Fall back to AA if READABLE is unreachable on this surface.
                    if (bgL > 0.5 && !fixedEls.has(el)) {
                        const en = enforceLightness(fgC, bgL, READABLE) || enforceLightness(fgC, bgL, AA);
                        if (en && ratio(relLum(en), bgL) > r) {
                            el.style.setProperty('color', 'rgb(' + en.r + ', ' + en.g + ', ' + en.b + ')', 'important');
                            el.setAttribute('data-ytm-fixed', '1');
                            fixedEls.add(el);
                            r = ratio(relLum(en), bgL);
                        }
                    // dark text stranded on an opaque-dark surface the cascade missed
                    // (inline style / shorthand bg) -> lighten that surface in place.
                    } else if (isDarkOpaqueGray(eb.c) && !bgFixedEls.has(eb.el)) {
                        const inv = invert('rgb(' + eb.c.r + ',' + eb.c.g + ',' + eb.c.b + ')'), ic = inv && toRGB(inv);
                        if (ic) {
                            eb.el.style.setProperty('background-color', inv, 'important');
                            bgFixedEls.add(eb.el);
                            r = ratio(fgL, relLum(ic));
                        }
                    }
                }
                if (r < AA) failing++;
            }

            // Icon pass (WCAG 1.4.11, 3:1). The bulk inversion can flip a dark glyph to
            // near-white; on a light surface that's an invisible control. Darken NEUTRAL
            // (near-grayscale) icon fills that fail 3:1 against a light effective bg.
            // Excluded — and these are exactly the icons that SHOULD stay light:
            //   • over media (white glyph on album art + scrim)
            //   • on a dark/coloured surface (e.g. the white triangle on the #f03 play button)
            //   • saturated/brand glyphs (semantic colour, conveyed redundantly)
            const mediaRects = [].slice.call(document.querySelectorAll('img, yt-img-shadow, [style*="background-image"]'))
                // Real media only: a background-image counts as "media" ONLY if it's an actual
                // url() image — NOT a gradient. imgs always count.
                .filter(m => m.tagName === 'IMG' || m.tagName === 'YT-IMG-SHADOW' || /url\(/i.test(getComputedStyle(m).backgroundImage))
                // …and exclude the immersive full-bleed BACKDROP (a blurred cover image behind
                // the whole page): a glyph over it isn't "on artwork", it's on the page, so it
                // must stay dark. Match it by its OWNING container — robust on a narrow window,
                // where a width cap alone would let a < cap-width backdrop slip through. The
                // width cap stays as a backstop for any other full-bleed surface; foreground art
                // (thumbnails/covers) is ≤ ~540px and not inside these immersive containers.
                .filter(m => !m.closest('ytmusic-fullbleed-thumbnail, ytmusic-immersive-header-renderer, .background-gradient'))
                .map(m => m.getBoundingClientRect()).filter(b => b.width > 24 && b.height > 24 && b.width < 700);
            const overMedia = (r) => { const cx = r.left + r.width / 2, cy = r.top + r.height / 2; return mediaRects.some(b => cx >= b.left && cx <= b.right && cy >= b.top && cy <= b.bottom); };
            for (const ic of document.querySelectorAll('button svg, a svg, [role="button"] svg, tp-yt-paper-icon-button svg, yt-icon svg')) {
                if (iconFixedEls.has(ic)) continue;
                if (ic.closest('#milkviz-canvas-host')) continue;   // visualizer-owned overlay (FS button + bar) sets its own white icons (matches YT media controls)
                const ir = ic.getBoundingClientRect();
                if (ir.width < 10 || ir.width > 56 || ir.height < 10 || ir.bottom < 0 || ir.top > innerHeight) continue;
                const ist = getComputedStyle(ic);
                if (ist.visibility === 'hidden' || (+ist.opacity) < 0.4) continue;
                let fc = (ist.fill && ist.fill !== 'none' && ist.fill !== 'rgba(0, 0, 0, 0)') ? toRGB(ist.fill) : toRGB(ist.color);
                if (!fc || fc.a < 0.4) continue;
                if (Math.max(fc.r, fc.g, fc.b) - Math.min(fc.r, fc.g, fc.b) > 40) continue;   // saturated → semantic, leave it
                // Over album/video art (#6): the neutral glyph should be WHITE, like dark mode
                // (e.g. the ⋮ "More" button rides the thumbnail's gradient). The bulk inverter
                // had flipped it near-black; re-whiten it here instead of leaving it dark.
                if (overMedia(ir)) {
                    ic.style.setProperty('fill', 'rgb(255, 255, 255)', 'important');
                    ic.style.setProperty('color', 'rgb(255, 255, 255)', 'important');
                    iconFixedEls.add(ic);
                    continue;
                }
                const ibg = effectiveBg(ic).c;
                if (relLum(ibg) < 0.5) continue;                  // dark/coloured surface → a light glyph is correct
                if (ratio(relLum(fc), relLum(ibg)) >= 3) continue; // already fine
                ic.style.setProperty('fill', 'rgb(20, 20, 20)', 'important');
                ic.style.setProperty('color', 'rgb(20, 20, 20)', 'important');
                iconFixedEls.add(ic);
            }

            const coverage = total ? 1 - failing / total : 1;
            document.documentElement.setAttribute('data-ytm-coverage', Math.round(coverage * 100));

            // #2: bail to native dark only on *sustained* poor coverage — not the
            // transient dips while a page streams in. Skip the eager boot passes,
            // then require several consecutive bad reads before giving up.
            auditCount++;
            const bad = total > 30 && coverage < 0.85;
            lowStreak = (auditCount > 8 && bad) ? lowStreak + 1 : 0;
            if (lowStreak >= 4) {
                degraded = true;
                clearFixes();
                restorePins();
                document.documentElement.setAttribute('data-ytm-mode', 'dark');
                document.documentElement.setAttribute('data-ytm-degraded', '1');
            }
            // Adaptive backoff bookkeeping: a meaningful, fully-clean read banks a stable
            // tick; ANY failure (or an empty page) resets, so we only coast once the page
            // has genuinely settled at full coverage.
            if (total > 30) stableAudits = failing === 0 ? stableAudits + 1 : 0;
            return coverage;
        }

        // ---------- drive mode from macOS appearance (the "system pref" behavior) ----------
        // Seed from the native-supplied appearance (window.__ytmNativeDark): a WKWebView's
        // prefers-color-scheme isn't reliably settled at load, so a media-query read can
        // miss light mode until a system toggle. The native value is correct from frame 1;
        // the live media query then takes over for runtime changes.
        const mq = window.matchMedia('(prefers-color-scheme: dark)');
        const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
        let systemDark = (typeof window.__ytmNativeDark === 'boolean') ? window.__ytmNativeDark : mq.matches;
        // While anything is in element-fullscreen (the visualizer, or YT's own video player),
        // stand the light engine down so fullscreen content renders in YT's native dark —
        // otherwise the inverted player chrome bleeds a light bar into the immersive view.
        let fullscreenActive = false;
        window.__ytmSetSystemDark = function (d) { systemDark = !!d; applyMode(true); };   // switchMode runs the pins (correctly, after the flip)
        // A real toggle (dark<->light) crossfades via the View Transitions API; every
        // other call (the per-tick re-assert, boot, fullscreen) flips instantly.
        // pendingMode holds the target of an in-flight transition so a concurrent
        // no-animate tick can't flip the attribute out from under it (startViewTransition's
        // update callback runs asynchronously — the flip happens a microtask later).
        let pendingMode = null;
        // The full mode switch: leave-light cleanup + the attribute flip + the inline
        // pins, run SYNCHRONOUSLY here so the View Transition's "new" snapshot is the
        // fully-resolved frame (the pins otherwise land a tick later, which the frozen
        // crossfade would show as a half-themed header). The pins are all mode-aware —
        // each APPLIES its inline value in light and REMOVES it in dark — so running them
        // in both directions also cleans up the light token/nav pins on the way to dark.
        function switchMode(next) {
            pendingMode = null;
            if (next !== 'light') { clearFixes(); restorePins(); stableAudits = 0; }   // leaving light: drop ALL inline fixes, re-arm audit cadence for re-entry
            document.documentElement.setAttribute('data-ytm-mode', next);
            safe(pinTokens); safe(pinNav); safe(pinImmersive); safe(pinMenu); safe(pinLogo);
        }
        function applyMode(animate) {
            if (degraded) return;
            const de = document.documentElement;
            const next = (!systemDark && !fullscreenActive) ? 'light' : 'dark';
            if (pendingMode === next) return;                                      // a transition is already flipping to this
            if (pendingMode === null && de.getAttribute('data-ytm-mode') === next) return;   // already there (the common per-tick case)
            const prev = de.getAttribute('data-ytm-mode');
            // Animate only a genuine toggle: prev must be a real prior mode (never at boot,
            // where prev is null — there's nothing to crossfade from), the API must exist,
            // motion must be allowed, and the page must be visible (a transition on a hidden
            // page would fade in from a stale snapshot when it resurfaces).
            const canAnimate = animate && (prev === 'light' || prev === 'dark')
                && typeof document.startViewTransition === 'function'
                && !reduceMotion.matches && document.visibilityState === 'visible';
            if (!canAnimate) { switchMode(next); return; }
            pendingMode = next;
            try {
                // Mark <html> so the tuned crossfade duration (see the base stylesheet's
                // `html.ytm-theme-vt::view-transition-*` rule) applies to OUR transition
                // only — never restyling a view transition some other page code might run.
                de.classList.add('ytm-theme-vt');
                const done = () => de.classList.remove('ytm-theme-vt');
                const vt = document.startViewTransition(() => switchMode(next));
                // A skipped transition (rapid re-toggle) rejects ready/finished — its update
                // callback still runs, so just swallow the rejects and always drop the marker.
                if (vt) {
                    if (vt.ready && vt.ready.catch) vt.ready.catch(() => {});
                    if (vt.finished && vt.finished.then) vt.finished.then(done, done); else done();
                } else { done(); }
            } catch (e) { de.classList.remove('ytm-theme-vt'); switchMode(next); }   // WKWebView lifecycle edge: fall back to an instant flip
        }

        // #nav-bar-background is recolored inline by YT (dark, from page content +
        // scroll), with !important — beats any stylesheet. YT also *replaces* the
        // element across navigations, so we re-query it every call rather than cache,
        // pin it inline to a primitive we control, and watch its style for rewrites.
        let navWired = false;
        function pinNav() {
            const el = document.getElementById('nav-bar-background');
            if (!el) return;
            const light = !degraded && document.documentElement.getAttribute('data-ytm-mode') === 'light';
            // Dark/native: undo ONLY our pin. Remove background only if it still holds our
            // pinned value (YT may have rewritten it since), and never touch 'animation' —
            // we cancel WAAPI animations below, we never set an inline animation, so removing
            // it would strip YT's own.
            if (!light) {
                if (el.__ytmNavPinned && el.style.getPropertyValue('background').indexOf('243, 243, 243') >= 0) el.style.removeProperty('background');
                el.__ytmNavPinned = false;
                return;
            }
            // YT animates this element's colour via the Web Animations API, which
            // outranks even inline !important — cancel those, then pin the fixed light
            // surface (a constant, since YT poisons our --ytmusic-* primitives here).
            if (el.getAnimations) el.getAnimations().forEach(a => a.cancel());
            const want = 'rgb(243, 243, 243)';
            if (getComputedStyle(el).backgroundColor !== want) el.style.setProperty('background', want, 'important');
            el.__ytmNavPinned = true;
            if (!el.__ytmNavObs) {
                el.__ytmNavObs = true;
                new MutationObserver(pinNav).observe(el, { attributes: true, attributeFilter: ['style'] });
            }
            if (!navWired) {
                navWired = true;
                addEventListener('scroll', pinNav, { capture: true, passive: true });
                setInterval(pinNav, 300);   // backstop against frame-driven rewrites
            }
        }

        // The account-menu popup paints its surface from the Material chain (resolves
        // dark) via `background: var()`, which beats our scoped stylesheet rule. Pin it
        // inline (inline wins) whenever it's still dark.
        function pinMenu() {
            if (degraded || document.documentElement.getAttribute('data-ytm-mode') !== 'light') return;
            for (const el of document.querySelectorAll('ytmusic-multi-page-menu-renderer, .ytmusicMultiPageMenuRendererHost')) {
                const c = toRGB(getComputedStyle(el).backgroundColor);
                if (c && c.a >= 1 && lumOf(c) < 0.5) { el.style.setProperty('background-color', 'rgb(250, 250, 250)', 'important'); menuFixed.add(el); }
            }
        }

        // The nav-bar wordmark is a single SVG (on_platform_logo_dark.svg) with the red
        // play button (#f03) AND the word "Music" baked in white — so on a light surface
        // "Music" disappears, and there's no light asset (the _light variant 404s) and no
        // way to recolour part of an external <img> with CSS. So we take YT's OWN svg and
        // recolour ONLY the white wordmark to near-black, leaving #f03 untouched — exactly
        // what an official light logo would be, zero design change. Fetched + rewritten at
        // runtime (not hardcoded), so it self-heals if Google updates the asset.
        let logoUri = null, logoFetching = false, logoOrigSrc = null;
        function pinLogo() {
            const img = document.querySelector('ytmusic-logo img.logo');
            if (!img) return;
            const light = !degraded && document.documentElement.getAttribute('data-ytm-mode') === 'light';
            if (!light) { if (logoOrigSrc && img.src.indexOf('data:') === 0) img.src = logoOrigSrc; return; }
            if (!logoUri) {
                if (logoFetching) return;
                if (!logoOrigSrc) logoOrigSrc = img.src;
                logoFetching = true;
                // Darken ONLY the wordmark. In YT's SVG the "Music" letters are one group
                // (<g fill="#fff">…</g>); the play button is a separate #f03 circle whose
                // ring (stroke="#fff") and triangle (fill="#fff") must STAY white. So we
                // recolour just that group's fill — not a blanket #fff swap, which also
                // darkened the triangle/ring and made the button look black.
                fetch(logoOrigSrc).then(r => r.ok ? r.text() : null).then(svg => {
                    if (!svg || svg.indexOf('<svg') < 0) return;        // not the SVG (404/HTML/blocked) — leave the logo as-is
                    const lit = svg.replace(/<g fill="#fff">/i, '<g fill="#0f0f0f">');
                    if (lit === svg) return;                            // wordmark group not found (asset changed) — don't ship an unrecoloured copy
                    logoUri = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(lit);
                    schedule();                                         // apply now, even if no further mutation fires a tick
                }).catch(() => {}).finally(() => { logoFetching = false; });
                return;
            }
            if (img.src !== logoUri) img.src = logoUri;   // re-assert (YT re-renders the logo across nav)
        }

        // The immersive header backdrop (.background-gradient) is given a dark,
        // content-derived gradient INLINE by YT, which our stylesheet inversion can't
        // reach. Invert its stops in place (keeping the light/colourful look) whenever
        // it's still dark; the value-compare via luma stops it from looping.
        function pinImmersive() {
            if (degraded || document.documentElement.getAttribute('data-ytm-mode') !== 'light') return;
            for (const el of document.querySelectorAll('.background-gradient')) {
                const bi = getComputedStyle(el).backgroundImage;
                if (!bi || bi.indexOf('gradient') < 0) continue;
                const first = bi.match(/rgba?\([^)]*\)|#[0-9a-fA-F]{3,8}/);
                const c = first && toRGB(first[0]);
                if (c && lumOf(c) < 0.5) {
                    if (!immFixed.has(el)) immFixed.set(el, el.style.getPropertyValue('background-image'));
                    el.style.setProperty('background-image', invertColorsInString(bi), 'important');
                }
            }
        }

        // YT's immersive theming writes the semantic background tokens INLINE on the
        // root (a dark, content-derived colour) — inline beats our stylesheet, even
        // !important. So we pin our light values inline on <html> too and re-assert
        // whenever YT rewrites them (value-compare guard → no observer ping-pong).
        // These literals are the inverted primitives (#030303→#f3f3f3, #181818→#e7e7e7,
        // #212121→#dedede); the rest of the palette follows via the cascade.
        const PIN_TOKENS = {
            '--ytmusic-background': 'rgb(243, 243, 243)',
            '--ytmusic-general-background-a': 'rgb(231, 231, 231)',
            '--ytmusic-general-background-b': 'rgb(231, 231, 231)',
            '--ytmusic-general-background-c': 'rgb(243, 243, 243)',
            '--ytmusic-nav-bar': 'rgb(243, 243, 243)',
            '--ytmusic-player-page-background': 'rgb(243, 243, 243)',
            '--ytmusic-brand-background-solid': 'rgb(222, 222, 222)'
        };
        let tokensWired = false;
        function pinTokens() {
            const de = document.documentElement;
            if (degraded || de.getAttribute('data-ytm-mode') !== 'light') {
                // Only undo OUR pins. If YT has since written its own (dark, immersive)
                // value for a token, leave it — a blind remove would fight native dark.
                for (const k in PIN_TOKENS) if (de.style.getPropertyValue(k) === PIN_TOKENS[k]) de.style.removeProperty(k);
                return;
            }
            for (const k in PIN_TOKENS) {
                if (de.style.getPropertyValue(k) !== PIN_TOKENS[k]) de.style.setProperty(k, PIN_TOKENS[k], 'important');
            }
            if (!tokensWired) {
                tokensWired = true;
                new MutationObserver(pinTokens).observe(de, { attributes: true, attributeFilter: ['style'] });
            }
        }

        // Read-only status hook for diagnostics / the Playwright harness. Returns the
        // live coverage score and how many in-place fixes are active. Never mutates.
        window.__ytmReport = function () {
            const de = document.documentElement;
            return {
                mode: de.getAttribute('data-ytm-mode'),
                degraded: degraded,
                coverage: +(de.getAttribute('data-ytm-coverage') || 0),
                tokens: knownTokens,
                selectorFixes: knownSel,
                textFixes: fixedEls.size,
                surfaceBorders: surfFixedEls.size,
                bgFixes: bgFixedEls.size,
                auditRuns: auditCount,   // how many full audits have run (backoff makes this grow slower once stable)
                stable: stableAudits     // consecutive clean audits banked toward the backoff threshold
            };
        };

        // ---------- scheduling: rebuild on DOM settle, re-audit, re-pin ----------
        // build() always runs (its own grew-guard skips the expensive CSS rebuild when
        // no new tokens appeared) — YT streams rules INTO existing stylesheets after
        // their count stabilises, so gating on styleSheets.length misses them.
        let pending = 0;
        let surfTick = 0;
        // Run each step independently: a throw in one pin must NOT stop the others
        // (a single try around all of them once let a failing earlier pin silently
        // skip pinImmersive, so the dark gradient came back). Returns the fn's result so
        // tick() can read build()'s "rebuilt?" signal.
        function safe(fn) { try { return fn(); } catch (e) { /* isolated; next tick retries */ } }
        // Adaptive audit backoff: the pins are cheap (a handful of getComputedStyle); the
        // two audits each walk the whole ~10k-node DOM. Once contrast has been clean for
        // STABLE_AFTER consecutive audits we stop walking every tick and only re-check
        // every BACKOFF-th tick — cutting steady-state cost ~BACKOFF×. A build() rebuild
        // (new lazily-loaded CSS = possibly un-themed content) re-arms full cadence at
        // once, so late drift is still caught immediately, not BACKOFF ticks later.
        const STABLE_AFTER = 6, BACKOFF = 6;
        let lastHref = location.href, lastRun = 0;
        function tick() {
            lastRun = Date.now();
            // SPA navigation (clicking a playlist/Home/Explore) swaps the page without a
            // reload. If the audit had backed off on the previous page, the NEW page's
            // inline/token-coloured secondary text would stay light for several ticks.
            // Re-arm full cadence on every URL change so each page themes immediately.
            if (location.href !== lastHref) { lastHref = location.href; stableAudits = 0; }
            safe(applyMode);   // re-assert mode each tick so load/refresh stay correct
            const grew = safe(build);
            safe(pinTokens);
            safe(pinNav);
            safe(pinImmersive);
            safe(pinMenu);
            safe(pinLogo);
            if (grew) stableAudits = 0;   // new styled content arrived → audit at full cadence
            auditTick++;
            if (stableAudits < STABLE_AFTER || auditTick % BACKOFF === 0) {
                safe(audit);
                if (++surfTick % 3 === 0) safe(auditSurfaces);   // throttle the full-DOM surface scan
            }
        }
        // THROTTLE, not debounce. YT streams a page's content in over 1-2s as a burst of
        // mutations; a pure debounce (reset-timer-on-every-mutation) never fires until the
        // burst pauses, so a freshly-navigated page stays un-themed (light text) the whole
        // time. Throttling guarantees a tick at least every ~300ms DURING the burst, so new
        // content is themed as it lands. Steady state is unaffected (mutations are rare and
        // the backoff still gates the expensive audit).
        function schedule() {
            if (pending) return;
            const since = Date.now() - lastRun;
            const wait = since >= 300 ? 0 : 300 - since;
            pending = setTimeout(() => { pending = 0; tick(); }, wait);
        }

        mq.addEventListener('change', () => { systemDark = mq.matches; applyMode(true); schedule(); });
        // Enter/exit fullscreen flips the engine off/on (same re-apply path as a system
        // appearance change): on exit, applyMode() restores light and schedule() re-themes.
        document.addEventListener('fullscreenchange', () => { fullscreenActive = !!document.fullscreenElement; applyMode(); schedule(); });

        // Start once the document root exists. The app injects at WKWebView document
        // start (where <html> is already present), but other injectors (e.g. the test
        // harness) run earlier — so wait for <html> rather than assume it.
        function start() {
            if (!document.documentElement) { setTimeout(start, 0); return; }
            applyMode();
            tick();
            // Re-theme as YT streams in late CSS / new views (closes the lazy-load gap).
            // Re-arm full-cadence auditing whenever NODES ARE ADDED (lazy-loaded carousel
            // rows, infinite scroll). Otherwise, once the page settled into backoff, new
            // content that reuses existing CSS (so build() doesn't grow) would wait up to
            // BACKOFF ticks to get themed — long enough to read as light text on scroll.
            new MutationObserver((muts) => {
                for (const m of muts) { if (m.addedNodes && m.addedNodes.length) { stableAudits = 0; break; } }
                schedule();
            }).observe(document.documentElement, { childList: true, subtree: true });
            // A few eager early passes during initial load, then rely on the observer.
            let boots = 0; const bootTimer = setInterval(() => { tick(); if (++boots >= 6) clearInterval(bootTimer); }, 800);
        }
        start();
    })();
    """#
}
