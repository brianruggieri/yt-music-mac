// Audio sink: native PCM (window.__milkFeed) -> AudioWorklet -> Butterchurn.
// Task 7 owns canvas mounting, sizing, and the render loop; this file only gets
// audio flowing and exposes the test hooks (MilkViz.viz, MilkViz.audioLevel()).
(function () {
    'use strict';

    const MilkViz = window.MilkViz = window.MilkViz || {};

    let ctx = null;
    let node = null;
    let analyser = null;
    let levelBuf = null;
    let initPromise = null;

    // Butterchurn 2.6.7 UMD is built without libraryExport:'default', so the
    // global is the webpack namespace — the real API lives at `.default`.
    function resolveButterchurn() {
        return window.butterchurn && (window.butterchurn.default || window.butterchurn);
    }

    async function init() {
        ctx = new (window.AudioContext || window.webkitAudioContext)();

        // A worklet must load into the AudioWorklet context, so visualizer.js
        // receives its source as a string (window.__pcmWorkletSource, injected
        // natively) and builds a blob: module URL — proven under YT Music CSP.
        const blob = new Blob([window.__pcmWorkletSource], { type: 'application/javascript' });
        const url = URL.createObjectURL(blob);
        await ctx.audioWorklet.addModule(url);
        URL.revokeObjectURL(url);

        node = new AudioWorkletNode(ctx, 'pcm-worklet', {
            numberOfOutputs: 1,
            outputChannelCount: [2],
        });

        // Zero-gain sink keeps the Web Audio graph pulled (required to render).
        const sink = ctx.createGain();
        sink.gain.value = 0;
        node.connect(sink);
        sink.connect(ctx.destination);

        // Analyser drives audioLevel() — independent of Butterchurn's own tap.
        analyser = ctx.createAnalyser();
        analyser.fftSize = 2048;
        levelBuf = new Float32Array(analyser.fftSize);
        node.connect(analyser);

        // ponytail: detached canvas + placeholder size; Task 7 mounts/sizes it.
        const butterchurn = resolveButterchurn();
        const canvas = document.createElement('canvas');
        canvas.width = 1280;
        canvas.height = 720;
        const viz = butterchurn.createVisualizer(ctx, canvas, {
            width: canvas.width,
            height: canvas.height,
            pixelRatio: window.devicePixelRatio || 1,
        });
        viz.connectAudio(node);

        MilkViz.viz = viz;
        MilkViz.canvas = canvas;
    }

    function ensureInit() {
        if (!initPromise) {
            initPromise = init().catch((e) => {
                initPromise = null;        // allow a later feed to retry
                console.error('MilkViz init failed', e);
            });
        }
        return initPromise;
    }

    // Called ~60 Hz by native with base64 of interleaved-stereo Float32LE.
    // The first feeds kick off async init and are dropped until the node exists.
    window.__milkFeed = function (b64) {
        // First feed since activation cancels the no-audio fallback timer, and arms the
        // silent-feed denial check (feed flowing but level stays 0 while playing).
        if (!_feedArrived) { _feedArrived = true; clearNoAudioTimer(); armSilentCheck(); }
        if (!node) { ensureInit(); return; }
        // AudioContext may start suspended under the autoplay policy; resume so
        // the graph actually pulls the worklet. May require a page gesture.
        if (ctx.state === 'suspended') ctx.resume();
        const buf = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)).buffer;
        node.port.postMessage(new Float32Array(buf), [buf]);   // transfer: zero-copy
    };

    // RMS of the most recent analyser window — a reliable nonzero-tracks-music
    // readout for tests.
    MilkViz.audioLevel = function () {
        if (!analyser) return 0;
        analyser.getFloatTimeDomainData(levelBuf);
        let sum = 0;
        for (let i = 0; i < levelBuf.length; i++) sum += levelBuf[i] * levelBuf[i];
        return Math.sqrt(sum / levelBuf.length);
    };

    // --- Task 7: canvas mount, render loop, resize handling ---

    let _container = null;
    let _resizeObs = null;
    let _fallbackMsg = null;
    let _rafId = null;
    let _loopActive = false;

    function hasWebGL2() {
        try { return !!document.createElement('canvas').getContext('webgl2'); }
        catch (_) { return false; }
    }

    // Recompute backing-store size and notify Butterchurn. Requires viz + canvas
    // to exist and the canvas to be mounted (so clientWidth/Height are nonzero).
    // Measure the CANVAS, not the host: the host has padding (Part B breathing room)
    // so clientWidth would include it, but the width:100% canvas fills only the
    // host's content box — measuring the canvas keeps backing store == displayed size.
    function applySize() {
        if (!MilkViz.canvas || !MilkViz.viz || !_container) return;
        const dpr = window.devicePixelRatio || 1;
        const w = Math.floor(MilkViz.canvas.clientWidth * dpr);
        const h = Math.floor(MilkViz.canvas.clientHeight * dpr);
        if (w === 0 || h === 0) return;
        MilkViz.canvas.width = w;
        MilkViz.canvas.height = h;
        MilkViz.viz.setRendererSize(w, h);
    }

    // ponytail: single rAF token; _loopActive flag makes resume() idempotent.
    function loop() {
        if (!_loopActive) return;
        _rafId = requestAnimationFrame(loop);
        if (MilkViz.viz) MilkViz.viz.render();
    }

    MilkViz.resume = function () {
        if (_loopActive) return;
        _loopActive = true;
        _rafId = requestAnimationFrame(loop);
    };

    MilkViz.pause = function () {
        _loopActive = false;
        if (_rafId !== null) { cancelAnimationFrame(_rafId); _rafId = null; }
    };

    // mount(container) — inserts canvas, starts render loop.
    // If WebGL2 unavailable: shows a static message div instead; render is a no-op.
    // If called before audio init has run: ensureInit() triggers it; canvas is
    // inserted once init resolves (viz-not-ready is handled transparently).
    MilkViz.mount = function (container) {
        if (!hasWebGL2()) {
            _fallbackMsg = document.createElement('div');
            _fallbackMsg.textContent = 'Visualizer needs WebGL2';
            _fallbackMsg.style.cssText = 'display:flex;align-items:center;justify-content:center;' +
                'width:100%;height:100%;color:#fff;font-family:sans-serif;font-size:1rem;';
            container.appendChild(_fallbackMsg);
            return;
        }

        _container = container;

        ensureInit().then(function () {
            // Bail if unmount (or a re-mount) changed _container while init was async —
            // otherwise a stale closure restarts the rAF loop on a detached canvas.
            if (_container !== container) return;
            // Guard against double-mount leaking the prior ResizeObserver.
            if (_resizeObs) { _resizeObs.disconnect(); _resizeObs = null; }

            const canvas = MilkViz.canvas;
            canvas.style.width = '100%';
            canvas.style.height = '100%';
            canvas.style.borderRadius = '10px';   // subtle inset corners within the padded host
            container.appendChild(canvas);
            applySize();

            _resizeObs = new ResizeObserver(applySize);
            _resizeObs.observe(container);

            MilkViz.resume();
        });
    };

    MilkViz.unmount = function () {
        MilkViz.pause();
        clearNoAudioTimer();        // Task 11: no background timer once unmounted
        clearStatusOverlay();
        if (_resizeObs) { _resizeObs.disconnect(); _resizeObs = null; }
        if (_fallbackMsg) { _fallbackMsg.remove(); _fallbackMsg = null; }
        if (MilkViz.canvas && MilkViz.canvas.parentNode) {
            MilkViz.canvas.parentNode.removeChild(MilkViz.canvas);
        }
        _container = null;
    };

    // --- Task 8: Visualizer toggle segment, overlay fallback, and mode lifecycle ---
    // Segment-detection selectors are best-effort — YT Music's DOM is not inspectable
    // headlessly. The overlay fallback is the guaranteed path until human QA confirms
    // which selectors actually match in the live app.

    let _active = false;
    let _segInjected = false;    // our Visualizer segment is currently in the DOM
    let _overlayBtn = null;      // fallback overlay button element
    let _canvasHost = null;      // div we mount the canvas into
    let _stageResizeHandler = null;  // window resize -> reposition fixed host
    let _t8FallbackTimer = null; // 5-second timer before injecting overlay fallback
    let _injectPending = false;  // debounce flag for MutationObserver callbacks

    // Guard: window.webkit?.messageHandlers?.visualizer only present in WKWebView context.
    function postVizAction(action) {
        try {
            if (window.webkit && window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.visualizer) {
                window.webkit.messageHandlers.visualizer.postMessage({ action });
            }
        } catch (e) {
            console.warn('MilkViz: postMessage failed', e);
        }
    }

    // Find the CONSISTENT stage region to size the visualizer to. From the live DOM:
    // `ytmusic-player #main-panel` is the stable stage box regardless of Song/Video
    // entry point (the media letterboxes within it), so prefer it over the media
    // element itself (which shrinks to album-art square vs 16:9 video).
    // Compute the consistent center-stage rect in viewport coords. Ground truth:
    // ytmusic-player-page stays 1272x688 in BOTH Song and Video, while ytmusic-player
    // (the media element) resizes to album(square)/video(16:9) — so we must NOT track
    // the media element. We carve the stage COLUMN out of the page: from the page's
    // left edge to the queue/side-panel's left edge, and from just below the Song/Video
    // toggle down to the page bottom. This excludes the toggle (stays clickable) and the
    // UP-NEXT queue (stays visible), and is identical regardless of Song/Video.
    function computeStageRect() {
        const page = document.querySelector('ytmusic-player-page');
        if (!page) return null;
        const pr = page.getBoundingClientRect();
        if (pr.width === 0 || pr.height === 0) return null;
        const tog = document.querySelector('ytmusic-av-toggle') || document.querySelector('div.av-toggle');
        const queue = document.querySelector('#side-panel') || document.querySelector('ytmusic-player-queue');
        const tr = tog && tog.getBoundingClientRect();
        const qr = queue && queue.getBoundingClientRect();
        const left = pr.left;
        const top = (tr && tr.bottom > pr.top) ? tr.bottom + 12 : pr.top;
        const right = (qr && qr.left > left + 50) ? qr.left : pr.right;
        const bottom = pr.bottom;
        return { left, top, width: Math.max(0, right - left), height: Math.max(0, bottom - top) };
    }

    // Is the now-playing page actually expanded? YT marks the open player page with
    // `player-page-open_` on ytmusic-app-layout. We key off that, with a geometric
    // fallback (page visibly on-screen) in case the attribute name drifts. Our canvas
    // host is position:fixed, so without this it keeps floating over Home/Explore after
    // the user collapses the player — it must close WITH the now-playing window.
    function isPlayerPageOpen() {
        const layout = document.querySelector('ytmusic-app-layout');
        if (layout && (layout.hasAttribute('player-page-open_') ||
                layout.hasAttribute('player-page-open'))) return true;
        const page = document.querySelector('ytmusic-player-page');
        if (!page) return false;
        const r = page.getBoundingClientRect();
        return r.height > 0 && r.top < window.innerHeight - 50;
    }

    // Current theme. __ytmNativeDark is a load-time seed (NSApp appearance) that is never
    // updated, so after a runtime light/dark swap it's stale. The light engine keeps
    // documentElement[data-ytm-mode] current on every swap — prefer it, seed as fallback.
    function currentDark() {
        var m = document.documentElement.getAttribute('data-ytm-mode');
        if (m === 'light') return false;
        if (m === 'dark') return true;
        return (window.__ytmNativeDark === true || window.__ytmNativeDark === 'true');
    }

    // The effective page background behind the stage — walk up from the player page to the
    // first opaque background. Used to tint the host padding frame so it blends with the page
    // (off-white in light, near-black in dark) in whatever theme YT is currently rendering.
    function pageBgColor() {
        var el = document.querySelector('ytmusic-player-page') || document.body;
        while (el) {
            var bg = getComputedStyle(el).backgroundColor;
            if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') return bg;
            el = el.parentElement;
        }
        return currentDark() ? '#0f0f0f' : '#F3F3F3';
    }

    // Position the fixed canvas host over the computed stage rect, then resize the canvas.
    function applyStageRect() {
        if (!_canvasHost) return;
        const r = computeStageRect();
        if (!r || r.width === 0 || r.height === 0) return;
        _canvasHost.style.inset = '';   // clear stale full-viewport fallback before setting explicit coords
        _canvasHost.style.left = r.left + 'px';
        _canvasHost.style.top = r.top + 'px';
        _canvasHost.style.width = r.width + 'px';
        _canvasHost.style.height = r.height + 'px';
        applySize();
    }

    // Find the REAL Song/Video control container. Ground truth from the live page:
    //   <ytmusic-av-toggle><div class="av-toggle ...">
    //     <button class="song-button ..." aria-pressed="false">Song</button>
    //     <button class="video-button ..." aria-pressed="false">Video</button>
    //   </div></ytmusic-av-toggle>
    // The `.av-toggle` div is the container; its direct children are the buttons.
    // Returns the container element, or null if not found.
    function findSegmentContainer() {
        // Primary: the real av-toggle div.
        const real = document.querySelector('ytmusic-av-toggle .av-toggle') ||
            document.querySelector('div.av-toggle');
        if (real) {
            console.log('MilkViz: segment found — av-toggle', real.className.slice(0, 40));
            return real;
        }

        // Fallback: a container whose direct children are buttons "Song" and "Video".
        const els = document.querySelectorAll('button, [role="button"], [role="tab"]');
        for (const el of els) {
            if (/^\s*song\s*$/i.test(el.textContent)) {
                const p = el.parentElement;
                if (p && Array.from(p.children).some((c) => /^\s*video\s*$/i.test(c.textContent))) {
                    console.log('MilkViz: segment found — text-scan fallback, parent:', p.tagName);
                    return p;
                }
            }
        }
        return null;
    }

    // We OWN the toggle's look and selection state. YT re-asserts aria-pressed on
    // song/video at track change, so we never drive the VISUAL off aria-pressed —
    // it's driven off the `.milkviz-sel` class we control (see syncSegState). These
    // helpers only set the a11y attribute on our own cloned button.
    function markPressed(el) { el.setAttribute('aria-pressed', 'true'); }
    function clearPressed(el) { el.setAttribute('aria-pressed', 'false'); }

    let _segAriaObs = null;   // watches YT flipping aria-pressed so we can re-sync
    let _syncing = false;     // re-entry guard for syncSegState

    // Scoped segmented-pill styling, injected once. Selectors are scoped to
    // `.av-toggle.milkviz-styled` so no other control is touched. Theme via
    // .milkviz-light / .milkviz-dark. Red is reserved for playing/brand elsewhere —
    // a mode toggle stays neutral.
    function injectToggleCss() {
        if (document.getElementById('milkviz-toggle-css')) return;
        const css = document.createElement('style');
        css.id = 'milkviz-toggle-css';
        css.textContent = [
            '.av-toggle.milkviz-styled{display:inline-flex !important;align-items:center !important;',
            'gap:2px !important;padding:3px !important;border-radius:999px !important;box-sizing:border-box !important;}',
            '.av-toggle.milkviz-styled.milkviz-light{background:#E7E7E7 !important;border:none !important;}',
            '.av-toggle.milkviz-styled.milkviz-dark{background:rgba(255,255,255,0.08) !important;border:1px solid rgba(255,255,255,0.10) !important;}',
            '.av-toggle.milkviz-styled>button{border:0 !important;background:transparent !important;border-radius:999px !important;',
            'padding:6px 18px !important;font:600 14px/1 "Roboto",sans-serif !important;letter-spacing:.2px !important;',
            'cursor:pointer !important;white-space:nowrap !important;transition:background .15s,color .15s !important;box-shadow:none !important;}',
            '.av-toggle.milkviz-styled.milkviz-light>button{color:#525252 !important;}',
            '.av-toggle.milkviz-styled.milkviz-dark>button{color:rgba(255,255,255,0.72) !important;}',
            '.av-toggle.milkviz-styled.milkviz-light>button:hover:not(.milkviz-sel){background:rgba(0,0,0,0.05) !important;}',
            '.av-toggle.milkviz-styled.milkviz-dark>button:hover:not(.milkviz-sel){background:rgba(255,255,255,0.06) !important;}',
            '.av-toggle.milkviz-styled.milkviz-light>button.milkviz-sel{background:#FFFFFF !important;color:#0A0A0A !important;}',
            // LightThemeEngine paints whichever of Song/Video YT has selected (its
            // `playback-mode` attr) as a white pill — but activating the Visualizer is an
            // overlay that never changes playback-mode, so Video stays "selected" alongside
            // our Visualizer. This (0,4,1) rule out-specifies that engine rule (0,3,1) and
            // strips the pill+shadow from any non-selected button, so exactly one reads selected.
            '.av-toggle.milkviz-styled.milkviz-light>button:not(.milkviz-sel){background:transparent !important;box-shadow:none !important;}',
            '.av-toggle.milkviz-styled.milkviz-dark>button.milkviz-sel{background:rgba(255,255,255,0.16) !important;color:#FFFFFF !important;}',
            '.av-toggle.milkviz-styled>button:focus-visible{outline:2px solid #1A73E8 !important;outline-offset:1px !important;}',
        ].join('');
        document.head.appendChild(css);
    }

    // Stamp our styling + current theme onto the container (re-evaluated each inject).
    function styleSegContainer(container) {
        injectToggleCss();
        container.classList.add('milkviz-styled');
        container.classList.remove('milkviz-light', 'milkviz-dark');
        container.classList.add(currentDark() ? 'milkviz-dark' : 'milkviz-light');
    }

    // Re-apply theme-dependent chrome when the page theme swaps at runtime: the host padding
    // frame color and the toggle's light/dark styling. Driven by the data-ytm-mode observer
    // below (the light engine flips that attribute on every swap).
    var _lastDark = null;
    function reTheme() {
        // The light engine re-stamps data-ytm-mode every tick (~300ms), firing this observer
        // even when the theme didn't change. Only do work on an actual light<->dark swap.
        var d = currentDark();
        if (d === _lastDark) return;
        _lastDark = d;
        if (_canvasHost && _active) {
            _canvasHost.style.background = (document.fullscreenElement === _canvasHost) ? '#000' : pageBgColor();
        }
        var c = findSegmentContainer();
        if (c && c.classList.contains('milkviz-styled')) { styleSegContainer(c); killButtonBorders(c); }
    }

    // Single source of truth for which segment LOOKS selected — exactly one.
    // Active  -> our Visualizer button. Inactive -> whichever of song/video YT has
    // aria-pressed (fallback: song). Visual is the `.milkviz-sel` class we own; we
    // also mirror aria-pressed onto OUR button for a11y, but only when it changes
    // (so the observer below can't loop).
    function syncSegState() {
        if (_syncing) return;
        _syncing = true;
        try {
            const container = document.querySelector('.av-toggle.milkviz-styled') ||
                document.querySelector('ytmusic-av-toggle .av-toggle') ||
                document.querySelector('div.av-toggle');
            if (!container) return;
            const seg = container.querySelector('#milkviz-seg-btn');
            const song = container.querySelector('.song-button');
            const video = container.querySelector('.video-button:not(#milkviz-seg-btn)');
            let target;
            if (_active && seg) {
                target = seg;
            } else {
                target = (song && song.getAttribute('aria-pressed') === 'true') ? song
                    : (video && video.getAttribute('aria-pressed') === 'true') ? video
                        : song;
            }
            Array.from(container.children).forEach(function (b) {
                b.classList.toggle('milkviz-sel', b === target);
            });
            if (seg) {
                const want = _active ? 'true' : 'false';
                if (seg.getAttribute('aria-pressed') !== want) seg.setAttribute('aria-pressed', want);
            }
        } finally {
            _syncing = false;
        }
    }

    // The app's LightThemeEngine repeatedly stamps an inline `border:1px solid
    // rgba(0,0,0,.12) !important` on each av-toggle button during its contrast audit —
    // inline !important beats our stylesheet, so light mode shows pill borders that dark
    // mode doesn't. Force the inline border (and outline) to 0 on every direct child.
    function killButtonBorders(container) {
        const c = container || document.querySelector('.av-toggle.milkviz-styled');
        if (!c) return;
        const dark = currentDark();
        // Light mode: strip the engine's inline border off the track container too (dark
        // keeps its subtle CSS track border). Buttons never carry a border in either theme.
        if (!dark) { c.style.setProperty('border', 'none', 'important'); }
        Array.from(c.children).forEach(function (el) {
            el.style.setProperty('border', '0', 'important');
            el.style.setProperty('outline', '0', 'important');
        });
    }

    let _borderObs = null;
    // Re-kill the engine's border whenever it re-adds it. Re-entry guard: only act when
    // a real border is actually present, so our own border:0 writes don't loop the observer.
    function watchSegBorders(container) {
        if (_borderObs) _borderObs.disconnect();
        _borderObs = new MutationObserver(function () {
            const c = document.querySelector('.av-toggle.milkviz-styled');
            if (!c) return;
            const dark = currentDark();
            // children should never have a border; in light, the container shouldn't either.
            const els = (!dark) ? [c].concat(Array.from(c.children)) : Array.from(c.children);
            const hasBorder = els.some(function (el) {
                return getComputedStyle(el).borderTopWidth !== '0px';
            });
            if (hasBorder) killButtonBorders(c);
        });
        _borderObs.observe(container, {
            attributes: true,
            attributeFilter: ['style', 'aria-pressed', 'class'],
            subtree: true,
        });
    }

    // Observe YT flipping song/video aria-pressed (e.g. it re-asserts Song on track
    // change) and re-sync. Our writes change `class`, not aria-pressed, so no loop.
    function watchSegAria(container) {
        if (_segAriaObs) _segAriaObs.disconnect();
        _segAriaObs = new MutationObserver(syncSegState);
        _segAriaObs.observe(container, { attributes: true, attributeFilter: ['aria-pressed'], subtree: true });
    }

    // Replace only the visible label text of a deep-cloned tab, preserving every
    // wrapper/icon/class. Swaps the first non-empty text node (the label).
    function setSegLabel(el, text) {
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
        let n;
        while ((n = walker.nextNode())) {
            if (n.nodeValue && n.nodeValue.trim()) { n.nodeValue = text; break; }
        }
        if (!n) el.textContent = text;   // fallback: no text node found
        if (el.hasAttribute('aria-label')) el.setAttribute('aria-label', text);
    }

    // Inject a "Visualizer" 3rd button into the av-toggle container.
    // DEEP-clone an existing button (the video-button) so it keeps YT's exact
    // class="video-button style-scope ytmusic-av-toggle" + inner structure — that
    // shared class is what makes ytmusic-av-toggle's scoped CSS style it identically.
    // We only change the id + label; selection state is the aria-pressed attribute.
    function injectSegment(container) {
        if (container.querySelector('#milkviz-seg-btn')) return;  // already there

        const siblings = Array.from(container.children).filter((c) => c.id !== 'milkviz-seg-btn');
        if (siblings.length === 0) return;

        // Clone the video-button if present (so we inherit its class), else any sibling.
        const tmpl = siblings.find((s) => s.classList && s.classList.contains('video-button'))
            || siblings[siblings.length - 1];

        const btn = tmpl.cloneNode(true);   // deep clone: keeps full inner structure
        btn.id = 'milkviz-seg-btn';
        clearPressed(btn);                  // unpressed default after clone
        // On audio-only tracks YT disables the Video tab; cloning it would copy the disabled
        // state, and a disabled <button> never dispatches click — making the visualizer
        // unreachable exactly there. Force it enabled.
        btn.disabled = false;
        btn.removeAttribute('disabled');
        btn.removeAttribute('aria-disabled');
        btn.classList.remove('disabled');
        setSegLabel(btn, 'Visualizer');
        btn.style.cursor = 'pointer';

        btn.addEventListener('click', (e) => {
            // Our button is synthetic; stop YT's toggle from also handling it.
            e.stopPropagation();
            MilkViz.setActive(!_active);   // setActive ends by calling syncSegState
        });

        // Clicking Song or Video deactivates the visualizer; then reflect YT's new
        // selection. YT updates aria-pressed after our capture-phase handler, so defer
        // the sync a tick (the aria observer also catches it as a backstop).
        siblings.forEach((sib) => {
            sib.addEventListener('click', () => {
                if (_active) MilkViz.setActive(false);
                setTimeout(syncSegState, 0);
            }, true);
        });

        container.appendChild(btn);   // 3rd child of .av-toggle
        styleSegContainer(container);
        killButtonBorders(container);   // strip the engine's inline light-mode borders
        watchSegBorders(container);     // and re-strip them whenever it re-adds them
        watchSegAria(container);
        syncSegState();               // single-active: exactly one .milkviz-sel
        _segInjected = true;
        console.log('MilkViz: Visualizer button injected (clone of',
            (tmpl.className || '').slice(0, 40), ')');
    }

    // Inject a floating fallback button when the segment control is absent.
    function injectOverlayBtn() {
        if (_overlayBtn) return;

        const btn = document.createElement('button');
        btn.id = 'milkviz-overlay-btn';
        btn.textContent = 'Visualizer';
        // ponytail: inline styles — no external CSS needed; works regardless of YT stylesheet
        btn.style.cssText =
            'position:fixed;top:12px;right:16px;z-index:9997;' +
            'padding:6px 14px;border-radius:16px;border:none;' +
            'background:rgba(255,255,255,0.15);color:#fff;' +
            'font-family:sans-serif;font-size:13px;cursor:pointer;' +
            'backdrop-filter:blur(4px);-webkit-backdrop-filter:blur(4px);';

        btn.addEventListener('click', () => {
            if (!_active) {
                btn.textContent = 'Close Visualizer';
                btn.style.background = 'rgba(200,50,50,0.6)';
                MilkViz.setActive(true);
            } else {
                btn.textContent = 'Visualizer';
                btn.style.background = 'rgba(255,255,255,0.15)';
                MilkViz.setActive(false);
            }
        });

        document.body.appendChild(btn);
        _overlayBtn = btn;
        console.log('MilkViz: overlay fallback button injected (Song/Video segment not found)');
    }

    // Core mode lifecycle. Idempotent: setActive(true) twice or setActive(false)
    // when already inactive are both no-ops.
    MilkViz.setActive = function (on) {
        if (on === _active) return;
        _active = on;

        if (on) {
            if (!_canvasHost) {
                _canvasHost = document.createElement('div');
                _canvasHost.id = 'milkviz-canvas-host';
                // Fixed overlay positioned over the consistent stage column (computed from
                // ytmusic-player-page, not the resizing media element). pointer-events:auto
                // so canvas clicks land on us (preset skip, Fix 3) not YT's play/pause.
                // Opaque bg hides the YT media behind the overlay; matched to the actual page
                // background so the 24px padding frame blends seamlessly (off-white in light,
                // near-black in dark) instead of being a hard white/black block.
                // z-index 3: sit in the same layer as YT's media stage (ytmusic-player-page is
                // fixed z-index:2; the video/art live inside it). Above the stage media, but below
                // the player-bar (4), nav-bar (5), tooltips (1002) and menu/dialog overlays
                // (iron-overlay-manager, >=1000) — so every YT popup stacks over the visualizer
                // exactly as it does over the video, instead of being hidden by our opaque bg.
                _canvasHost.style.cssText =
                    'position:fixed;z-index:3;background:' + pageBgColor() + ';pointer-events:auto;' +
                    'padding:24px;box-sizing:border-box;';   // breathing room: canvas insets from stage edges
                document.body.appendChild(_canvasHost);
                const r = computeStageRect();
                if (r) {
                    applyStageRect();
                    console.log('MilkViz: stage host', Math.round(r.width) + 'x' + Math.round(r.height));
                } else {
                    // ponytail: full-viewport fallback when the player page isn't found
                    _canvasHost.style.inset = '0';
                    console.log('MilkViz: stage host as full-viewport fallback');
                }
                if (!_stageResizeHandler) {
                    _stageResizeHandler = function () { applyStageRect(); };
                    window.addEventListener('resize', _stageResizeHandler);
                }
            }
            MilkViz.mount(_canvasHost);
            addFullscreenControl();
            MilkViz.resume();   // mount is async; resume is idempotent — starts loop immediately
            postVizAction('modeOn');
            startPresets();
            startNoAudioTimer();   // Task 11: hint if neither feed nor nativeStatus arrives
            syncSegState();        // Visualizer becomes the sole selected segment
        } else {
            stopPresets();
            removeFullscreenControl();
            MilkViz.unmount();
            if (_stageResizeHandler) { window.removeEventListener('resize', _stageResizeHandler); _stageResizeHandler = null; }
            if (_canvasHost) { _canvasHost.remove(); _canvasHost = null; }
            MilkViz.pause();    // unmount calls pause, but call again per spec
            postVizAction('modeOff');
            syncSegState();     // hand selection back to YT's current song/video
        }
    };

    // --- Task 11: Native status (permission / no-audio) overlays ---
    // The render loop keeps running with no PCM (idle, gentle motion); these overlays
    // only inform — they never tear the visualizer down. All cleaned up on deactivate
    // (via MilkViz.unmount) so no timer or DOM node survives the visualizer being off.

    let _statusOverlay = null;   // permission-error / no-audio message element
    let _feedArrived = false;    // any __milkFeed call since last activation
    let _statusArrived = false;  // any nativeStatus call since last activation
    let _noAudioTimer = null;    // ~3s fallback timer armed on activation
    let _silentCheckTimer = null; // ~5s denial check armed on first feed

    function clearStatusOverlay() {
        if (_statusOverlay) { _statusOverlay.remove(); _statusOverlay = null; }
    }

    // Centered message over the canvas host. pointer-events:none on the container so it
    // never blocks canvas clicks (preset skip); only the optional button takes events.
    function showStatusOverlay(message, withRetry) {
        clearStatusOverlay();
        if (!_canvasHost) return;
        const el = document.createElement('div');
        el.id = 'milkviz-status-overlay';
        el.style.cssText =
            'position:absolute;inset:0;display:flex;flex-direction:column;' +
            'align-items:center;justify-content:center;gap:14px;z-index:9999;' +
            'background:rgba(0,0,0,0.45);color:#fff;font-family:sans-serif;' +
            'font-size:15px;line-height:1.5;text-align:center;padding:24px;' +
            'pointer-events:none;white-space:pre-line;';
        const msg = document.createElement('div');
        msg.textContent = message;
        el.appendChild(msg);
        if (withRetry) {
            const btn = document.createElement('button');
            btn.textContent = 'Try again';
            btn.style.cssText =
                'pointer-events:auto;padding:6px 16px;border:none;border-radius:16px;' +
                'cursor:pointer;background:rgba(255,255,255,0.2);color:#fff;font-size:13px;';
            btn.addEventListener('click', function () {
                clearStatusOverlay();
                startNoAudioTimer();      // re-arm: a fresh modeOn may also stay silent
                // Full restart: native's modeOn is idempotent (returns early if a tap is
                // already running), so a silent/denied tap would never be recreated. Tear it
                // down first, then re-attempt — this is what lets "Try again" recover after
                // the user grants Audio Capture permission in System Settings.
                postVizAction('modeOff');
                setTimeout(function () { postVizAction('modeOn'); }, 250);
            });
            el.appendChild(btn);
        }
        _canvasHost.appendChild(el);
        _statusOverlay = el;
    }

    // Called by native (Task 4): {state:'ok'} on tap start, {state:'error',
    // code:'audioCaptureDenied'} on failure. Either way a status has arrived, so the
    // generic no-audio fallback timer is cancelled.
    MilkViz.nativeStatus = function (s) {
        _statusArrived = true;
        clearNoAudioTimer();
        if (!s) return;
        if (s.state === 'error' && s.code === 'audioCaptureDenied') {
            showStatusOverlay(
                'Audio capture permission needed\n' +
                'System Settings > Privacy & Security > Audio Capture',
                true);
        } else if (s.state === 'error') {
            // Generic, retryable setup failure (e.g. audioUnavailable) — NOT a permission
            // problem, so don't point the user at System Settings.
            showStatusOverlay('Couldn’t start the audio visualizer\nClick Try again', true);
        } else if (s.state === 'ok') {
            clearStatusOverlay();
        }
    };

    function clearNoAudioTimer() {
        if (_noAudioTimer) { clearTimeout(_noAudioTimer); _noAudioTimer = null; }
        if (_silentCheckTimer) { clearTimeout(_silentCheckTimer); _silentCheckTimer = null; }
    }

    function isPlaying() {
        if (navigator.mediaSession && navigator.mediaSession.playbackState) {
            return navigator.mediaSession.playbackState === 'playing';
        }
        var v = document.querySelector('video');
        return !!(v && !v.paused && v.currentTime > 0);
    }

    // Denial symptom: PCM frames ARE flowing (feed arrived) but the analyser stays silent
    // while a track is clearly playing -> Audio Capture was denied/revoked (capture returns
    // silence, not a start() error). This is the only reliable denial signal, so it's where
    // we surface the System Settings guidance (the start-failure path is generic on purpose).
    function armSilentCheck() {
        if (_silentCheckTimer) clearTimeout(_silentCheckTimer);
        _silentCheckTimer = setTimeout(function () {
            _silentCheckTimer = null;
            if (_active && isPlaying() && MilkViz.audioLevel() < 0.0005) {
                showStatusOverlay(
                    'No audio captured — permission may be needed\n' +
                    'System Settings > Privacy & Security > Audio Capture',
                    true);
            }
        }, 5000);
    }

    // Armed on activation: if no __milkFeed and no nativeStatus arrive within ~3s,
    // show a generic hint. Cancelled by the first feed or any status.
    function startNoAudioTimer() {
        clearNoAudioTimer();
        _feedArrived = false;
        _statusArrived = false;
        _noAudioTimer = setTimeout(function () {
            _noAudioTimer = null;
            if (!_feedArrived && !_statusArrived) showStatusOverlay('No audio detected', false);
        }, 3000);
    }

    // --- Task 9: Preset manager (auto-cycle, manual skip, track-change, name toast) ---
    // All timers and listeners are started on setActive(true) and fully torn down on
    // setActive(false) — no background work when the visualizer is off (battery).

    let _presetsObj = null;   // { [name]: presetObject } from butterchurnPresets.getPresets()
    let _presetNames = [];    // shuffled working list (capped at 40)
    let _presetIdx = 0;
    let _cycleTimer = null;
    let _trackPollTimer = null;
    let _lastTrackTitle = null;
    let _toastEl = null;

    // Resolve the preset global and build the working list once; _presetsObj guards re-entry.
    function initPresetList() {
        if (_presetsObj) return;
        const pg = window.butterchurnPresets;
        if (!pg) { console.warn('MilkViz: butterchurnPresets not found'); return; }
        const api = pg.default || pg;
        _presetsObj = api.getPresets();
        const allNames = Object.keys(_presetsObj);

        const curated = window.__milkPresets || [];
        let working = curated.length
            ? curated.filter(function (n) { return !!_presetsObj[n]; })  // drop invalid names
            : allNames;
        if (!working.length) working = allNames;   // fallback: intersection was empty

        // Fisher-Yates shuffle, cap at 40
        for (let i = working.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            const tmp = working[i]; working[i] = working[j]; working[j] = tmp;
        }
        _presetNames = working.slice(0, 40);
        console.log('MilkViz: preset list built —', _presetNames.length, 'presets');
    }

    // Auto-fading name toast over the canvas host.
    function showToast(name) {
        if (_toastEl) { _toastEl.remove(); _toastEl = null; }
        if (!_canvasHost) return;
        const el = document.createElement('div');
        el.textContent = name;
        el.style.cssText =
            'position:absolute;bottom:24px;left:50%;transform:translateX(-50%);' +
            'font-family:sans-serif;font-size:13px;' +
            'padding:4px 12px;border-radius:12px;pointer-events:none;z-index:9999;' +
            'opacity:1;transition:opacity 1s ease;white-space:nowrap;';
        // Force the toast palette inline-!important: it always sits over the dark visualizer
        // canvas, so it must stay white-on-dark in BOTH themes. The light-theme engine
        // otherwise inverts text to near-black (invisible here), like it does to controls.
        el.style.setProperty('color', '#fff', 'important');
        // -webkit-text-fill-color controls the painted glyph color and beats the light
        // engine's `color` inversion (which the engine applies inline-!important), so the
        // toast stays white over the dark canvas in light mode without needing an observer.
        el.style.setProperty('-webkit-text-fill-color', '#fff', 'important');
        el.style.setProperty('background', 'rgba(0,0,0,0.72)', 'important');
        _canvasHost.appendChild(el);
        _toastEl = el;
        setTimeout(function () { if (_toastEl === el) el.style.opacity = '0'; }, 2000);
        setTimeout(function () {
            if (_toastEl === el) { el.remove(); _toastEl = null; }
        }, 3100);
    }

    // Load preset at index i (wrapping), show toast.
    function doLoadPreset(i, blend) {
        if (!_presetsObj || !_presetNames.length || !MilkViz.viz) return;
        _presetIdx = ((i % _presetNames.length) + _presetNames.length) % _presetNames.length;
        const name = _presetNames[_presetIdx];
        MilkViz.viz.loadPreset(_presetsObj[name], blend != null ? blend : 2.7);
        showToast(name);
    }

    // Reschedule auto-advance; random interval 18-28s for variety.
    function scheduleCycle() {
        if (_cycleTimer) { clearTimeout(_cycleTimer); _cycleTimer = null; }
        var delay = 18000 + Math.random() * 10000;
        _cycleTimer = setTimeout(function () {
            doLoadPreset(_presetIdx + 1, 2.7);
            scheduleCycle();
        }, delay);
    }

    function _onKeyDown(e) {
        if (!_active) return;   // ponytail: guard (listener is only attached while active)
        if (e.key === 'ArrowRight') {
            e.preventDefault(); doLoadPreset(_presetIdx + 1, 2.7); scheduleCycle();
        } else if (e.key === 'ArrowLeft') {
            e.preventDefault(); doLoadPreset(_presetIdx - 1, 2.7); scheduleCycle();
        }
    }

    // YT's play/pause handler lives on ytmusic-player#player — an ANCESTOR of our
    // canvas — so a bubble-phase stopPropagation runs too late. Intercept on the
    // document in the CAPTURE phase: if the click landed on our canvas, kill it
    // before it reaches YT's player handler, then advance the preset. The fullscreen
    // button is not the canvas, so its own clicks pass the contains() check.
    function _onDocClickCapture(e) {
        if (!_active || !MilkViz.canvas || !MilkViz.canvas.contains(e.target)) return;
        e.stopImmediatePropagation();
        e.preventDefault();
        doLoadPreset(_presetIdx + 1, 2.7);
        scheduleCycle();
    }

    function _checkTrack() {
        var meta = navigator.mediaSession && navigator.mediaSession.metadata;
        var title = meta ? meta.title : null;
        if (title && title !== _lastTrackTitle) {
            _lastTrackTitle = title;
            doLoadPreset(_presetIdx + 1, 2.7);
            scheduleCycle();
        }
    }

    function startPresets() {
        initPresetList();
        if (!_presetNames.length) return;   // butterchurnPresets not available yet

        // Remove before add: prevents double-binding if re-activated after init resolved.
        document.removeEventListener('keydown', _onKeyDown);
        document.addEventListener('keydown', _onKeyDown);
        // Capture-phase, on document, to beat YT's ancestor play/pause handler (Fix 2).
        document.removeEventListener('click', _onDocClickCapture, true);
        document.addEventListener('click', _onDocClickCapture, true);

        var meta = navigator.mediaSession && navigator.mediaSession.metadata;
        _lastTrackTitle = meta ? meta.title : null;
        if (_trackPollTimer) { clearInterval(_trackPollTimer); }
        _trackPollTimer = setInterval(_checkTrack, 3000);

        // First preset requires viz to exist — wait for init.
        ensureInit().then(function () {
            if (!_active) return;   // deactivated while async init was in flight
            doLoadPreset(Math.floor(Math.random() * _presetNames.length), 0);
            scheduleCycle();
        });
    }

    function stopPresets() {
        if (_cycleTimer) { clearTimeout(_cycleTimer); _cycleTimer = null; }
        if (_trackPollTimer) { clearInterval(_trackPollTimer); _trackPollTimer = null; }
        document.removeEventListener('keydown', _onKeyDown);
        document.removeEventListener('click', _onDocClickCapture, true);
        if (_toastEl) { _toastEl.remove(); _toastEl = null; }
    }

    // --- Task 10: Fullscreen control ---
    // Replica of YT's video-player hover overlay: a top-down gradient plus a fullscreen
    // button in the TOP-RIGHT, both fading in only while the pointer is over the canvas
    // host. Lives on _canvasHost; gradient + button + listener torn down on setActive(false).

    let _fsBtn = null;
    let _fsGradient = null;
    let _fsChangeHandler = null;

    // Standard "enter fullscreen" glyph — four L-shaped corner brackets, white 2px strokes.
    const FS_ICON_SVG =
        '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="#fff" ' +
        'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
        '<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>' +
        '</svg>';

    // Hover reveal via CSS so it tracks the real pointer state on the fixed host.
    // !important beats the elements' inline opacity:0.
    function injectFsCss() {
        if (document.getElementById('milkviz-fs-css')) return;
        const css = document.createElement('style');
        css.id = 'milkviz-fs-css';
        css.textContent = [
            '#milkviz-canvas-host:hover #milkviz-fs-gradient{opacity:1 !important;}',
            '#milkviz-canvas-host:hover #milkviz-fs-btn{opacity:0.9 !important;}',
            '#milkviz-fs-btn:hover{opacity:1 !important;}',
        ].join('');
        document.head.appendChild(css);
    }

    // Called by native (in response to the fs button's 'enterFullscreen' message) so the
    // request runs without transient activation — the only context WebKit accepts here.
    MilkViz.enterFullscreen = function () {
        if (!_canvasHost || document.fullscreenElement) return;
        var req = _canvasHost.requestFullscreen || _canvasHost.webkitRequestFullscreen;
        if (req) req.call(_canvasHost);
    };

    function addFullscreenControl() {
        if (_fsBtn || !_canvasHost) return;
        injectFsCss();

        // Top gradient overlaying the canvas (z above it), revealed on host hover.
        const grad = document.createElement('div');
        grad.id = 'milkviz-fs-gradient';
        grad.style.cssText =
            'position:absolute;top:0;left:0;right:0;height:72px;' +
            'background:linear-gradient(to bottom, rgba(0,0,0,0.55), rgba(0,0,0,0));' +
            'opacity:0;transition:opacity .2s ease;pointer-events:none;z-index:2;';
        _canvasHost.appendChild(grad);
        _fsGradient = grad;

        // Fullscreen button at the top-right of the host.
        const btn = document.createElement('button');
        btn.id = 'milkviz-fs-btn';
        btn.title = 'Enter fullscreen';
        btn.setAttribute('aria-label', 'Enter fullscreen');
        btn.innerHTML = FS_ICON_SVG;
        btn.style.cssText =
            'position:absolute;top:14px;right:18px;width:28px;height:28px;' +
            'display:flex;align-items:center;justify-content:center;' +
            'opacity:0;transition:opacity .2s ease;cursor:pointer;pointer-events:auto;' +
            'z-index:3;border:none;background:transparent;padding:0;';

        // Sibling of the canvas, so the capture-phase preset-skip handler's
        // canvas.contains() check passes it through; stopPropagation is belt-and-braces.
        btn.addEventListener('click', function (e) {
            e.stopPropagation();
            if (document.fullscreenElement) {
                document.exitFullscreen();
                return;
            }
            // A real click carries transient activation, and WebKit rejects a gesture-initiated
            // element requestFullscreen here with a TypeError (fullscreenerror). Bounce through
            // native: it re-issues the request via evaluateJavaScript (no activation), which
            // WebKit accepts. enterFullscreen() below is what native calls back into.
            postVizAction('enterFullscreen');
        });

        _canvasHost.appendChild(btn);
        _fsBtn = btn;

        _fsChangeHandler = function () {
            const inFs = document.fullscreenElement === _canvasHost;
            if (_canvasHost) {
                // In fullscreen: edge-to-edge immersive — drop the breathing-room padding and
                // use a true black backdrop (no light-theme page bg bleeding into fullscreen).
                // Inline so it beats the page-bg the host carries from the windowed state.
                _canvasHost.style.padding = inFs ? '0' : '24px';
                _canvasHost.style.background = inFs ? '#000' : pageBgColor();
            }
            applySize();
            if (_fsBtn) {
                _fsBtn.title = inFs ? 'Exit fullscreen' : 'Enter fullscreen';
                _fsBtn.setAttribute('aria-label', _fsBtn.title);
            }
        };
        document.addEventListener('fullscreenchange', _fsChangeHandler);
        document.addEventListener('webkitfullscreenchange', _fsChangeHandler);
    }

    function removeFullscreenControl() {
        if (document.fullscreenElement) {
            document.exitFullscreen().catch(function () {});
        }
        if (_fsChangeHandler) {
            document.removeEventListener('fullscreenchange', _fsChangeHandler);
            document.removeEventListener('webkitfullscreenchange', _fsChangeHandler);
            _fsChangeHandler = null;
        }
        if (_fsBtn) { _fsBtn.remove(); _fsBtn = null; }
        if (_fsGradient) { _fsGradient.remove(); _fsGradient = null; }
    }

    // Debounced segment-injection check. Called by MutationObserver on DOM changes.
    function scheduleInjectCheck() {
        if (_injectPending) return;
        _injectPending = true;
        setTimeout(() => {
            _injectPending = false;
            if (_overlayBtn) return;   // already on fallback path — stop scanning
            if (document.querySelector('#milkviz-seg-btn')) return;  // segment still in DOM
            _segInjected = false;
            const container = findSegmentContainer();
            if (container) {
                if (_t8FallbackTimer) { clearTimeout(_t8FallbackTimer); _t8FallbackTimer = null; }
                injectSegment(container);
            }
        }, 200);
    }

    // Watch for the now-playing page collapsing while the visualizer is active, and
    // deactivate so the fixed canvas host doesn't float over the rest of the app. The
    // observer is attribute-only on the two elements YT flips on open/close, so it's cheap.
    function watchPlayerPageClose() {
        const layout = document.querySelector('ytmusic-app-layout');
        const page = document.querySelector('ytmusic-player-page');
        if (!layout && !page) { setTimeout(watchPlayerPageClose, 500); return; }
        let reCheck = null;
        const check = function () {
            if (!_active) return;
            if (!isPlayerPageOpen()) { MilkViz.setActive(false); return; }
            // YT can drop the open attribute at the START of the collapse animation while
            // the page is still geometrically on-screen; no further mutation is guaranteed
            // once the CSS transform finishes, so re-check after it settles to catch it.
            clearTimeout(reCheck);
            reCheck = setTimeout(function () { if (_active && !isPlayerPageOpen()) MilkViz.setActive(false); }, 350);
        };
        const obs = new MutationObserver(check);
        if (layout) obs.observe(layout, { attributes: true });
        if (page) obs.observe(page, { attributes: true });
    }

    // Boot the segment observer. Gated on __ytmVizSupported AND being on a YT Music page.
    function startSegObserver() {
        if (!window.__ytmVizSupported) {
            console.log('MilkViz: __ytmVizSupported falsy — visualizer toggle disabled');
            return;
        }
        // These user scripts also run on allowed full-page navigations (e.g. the
        // accounts.google.com sign-in flow). Never inject the toggle/overlay or start a
        // tap off music.youtube.com — there's no Song/Video control there and it would be
        // an out-of-place affordance capturing audio on an unrelated page.
        if (!/(^|\.)music\.youtube\.com$/.test(location.hostname)) {
            console.log('MilkViz: not a YT Music page (' + location.hostname + ') — skipping injection');
            return;
        }

        // Attempt injection immediately (page may already have the control).
        scheduleInjectCheck();

        // If segment control not found within 5s, fall back to overlay button.
        _t8FallbackTimer = setTimeout(() => {
            _t8FallbackTimer = null;
            if (!_segInjected) injectOverlayBtn();
        }, 5000);

        // MutationObserver re-injects after SPA navigation removes our segment.
        const obs = new MutationObserver(scheduleInjectCheck);
        obs.observe(document.body, { childList: true, subtree: true });

        // Tear the visualizer down when the now-playing page is collapsed/closed — our
        // fixed overlay would otherwise stick over Home/Explore. Fires only on player
        // open/close attribute changes, and only acts while the visualizer is active.
        watchPlayerPageClose();

        // Re-theme the host frame + toggle when the light engine flips the page theme.
        new MutationObserver(reTheme).observe(document.documentElement,
            { attributes: true, attributeFilter: ['data-ytm-mode'] });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', startSegObserver);
    } else {
        startSegObserver();
    }

})();
