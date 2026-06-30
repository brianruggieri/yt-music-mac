// Temporary boot marker — removed in Task 12.
window.__vizScriptLoaded = true;

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
    function applySize() {
        if (!MilkViz.canvas || !MilkViz.viz || !_container) return;
        const dpr = window.devicePixelRatio || 1;
        const w = Math.floor(_container.clientWidth * dpr);
        const h = Math.floor(_container.clientHeight * dpr);
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
            // Guard against double-mount leaking the prior ResizeObserver.
            if (_resizeObs) { _resizeObs.disconnect(); _resizeObs = null; }

            const canvas = MilkViz.canvas;
            canvas.style.width = '100%';
            canvas.style.height = '100%';
            container.appendChild(canvas);
            applySize();

            _resizeObs = new ResizeObserver(applySize);
            _resizeObs.observe(container);

            MilkViz.resume();
        });
    };

    MilkViz.unmount = function () {
        MilkViz.pause();
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

    // Best-effort: find the YT Music player stage element.
    function findStage() {
        return (
            document.querySelector('ytmusic-player') ||
            document.querySelector('#player-container-inner') ||
            document.querySelector('ytmusic-player-page') ||
            null
        );
    }

    // Best-effort: find the Song/Video segmented control container.
    // Logs which strategy matched so human QA can confirm or refine selectors.
    // Returns the parent container element, or null if not found.
    function findSegmentContainer() {
        // Strategy 1: ytmusic-segmented-buttons-renderer (most specific known selector).
        const known = document.querySelector('ytmusic-segmented-buttons-renderer');
        if (known) {
            const t = known.textContent || '';
            if (/\bsong\b/i.test(t) && /\bvideo\b/i.test(t)) {
                console.log('MilkViz: segment found — ytmusic-segmented-buttons-renderer');
                return known;
            }
        }

        // Strategy 2: [role="tab"] / YT-specific custom element variants.
        const tabs = Array.from(document.querySelectorAll(
            '[role="tab"], tp-yt-paper-tab, ytmusic-tab, ytmusic-segmented-button'
        ));
        const songTab = tabs.find((el) => /^\s*song\s*$/i.test(el.textContent));
        if (songTab) {
            const parent = songTab.parentElement;
            if (parent) {
                const sibs = Array.from(parent.children);
                if (sibs.some((el) => /^\s*video\s*$/i.test(el.textContent))) {
                    console.log('MilkViz: segment found — role=tab scan, parent:', parent.tagName);
                    return parent;
                }
            }
        }

        // Strategy 3: broad button/link text scan — last resort.
        const els = document.querySelectorAll('button, a, [role="button"], [role="tab"]');
        for (const el of els) {
            if (/^\s*song\s*$/i.test(el.textContent)) {
                const p = el.parentElement;
                if (!p) continue;
                if (Array.from(p.children).some((c) => /^\s*video\s*$/i.test(c.textContent))) {
                    console.log('MilkViz: segment found — text scan, parent:', p.tagName);
                    return p;
                }
            }
        }

        return null;
    }

    // Inject a "Visualizer" 3rd tab into the segment container.
    // Clones tag + class from a sibling so it inherits YT's light/dark theme.
    function injectSegment(container) {
        if (container.querySelector('#milkviz-seg-btn')) return;  // already there

        const siblings = Array.from(container.children);
        if (siblings.length === 0) return;

        const tmpl = siblings[0];
        const btn = document.createElement(tmpl.tagName);
        btn.id = 'milkviz-seg-btn';
        btn.className = tmpl.className;
        const role = tmpl.getAttribute('role');
        if (role) btn.setAttribute('role', role);
        btn.textContent = 'Visualizer';
        btn.style.cursor = 'pointer';

        btn.addEventListener('click', () => {
            if (!_active) {
                siblings.forEach((sib) => {
                    sib.removeAttribute('aria-selected');
                    sib.removeAttribute('selected');
                    sib.classList.remove('selected', 'iron-selected', 'tab-selected', 'active');
                });
                btn.setAttribute('aria-selected', 'true');
                MilkViz.setActive(true);
            } else {
                btn.removeAttribute('aria-selected');
                MilkViz.setActive(false);
            }
        });

        // Clicking Song or Video deactivates the visualizer.
        // capture:true so we run before YT's own handlers clear the selection.
        siblings.forEach((sib) => {
            sib.addEventListener('click', () => {
                if (_active) {
                    btn.removeAttribute('aria-selected');
                    MilkViz.setActive(false);
                }
            }, true);
        });

        container.appendChild(btn);
        _segInjected = true;
        console.log('MilkViz: Visualizer segment injected →',
            container.tagName, container.id || container.className.slice(0, 40));
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
                const stage = findStage();
                if (stage) {
                    // Overlay canvas on top of the player stage.
                    if (getComputedStyle(stage).position === 'static') {
                        stage.style.position = 'relative';
                    }
                    _canvasHost.style.cssText =
                        'position:absolute;inset:0;z-index:9998;background:#000;';
                    stage.appendChild(_canvasHost);
                    console.log('MilkViz: canvas host overlaid on', stage.tagName);
                } else {
                    // ponytail: fixed full-screen fallback when stage not found
                    _canvasHost.style.cssText =
                        'position:fixed;inset:0;z-index:9998;background:#000;';
                    document.body.appendChild(_canvasHost);
                    console.log('MilkViz: canvas host as fixed overlay (stage not found)');
                }
            }
            MilkViz.mount(_canvasHost);
            MilkViz.resume();   // mount is async; resume is idempotent — starts loop immediately
            postVizAction('modeOn');
        } else {
            MilkViz.unmount();
            if (_canvasHost) { _canvasHost.remove(); _canvasHost = null; }
            MilkViz.pause();    // unmount calls pause, but call again per spec
            postVizAction('modeOff');
        }
    };

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

    // Boot the segment observer. Gated entirely on __ytmVizSupported.
    function startSegObserver() {
        if (!window.__ytmVizSupported) {
            console.log('MilkViz: __ytmVizSupported falsy — visualizer toggle disabled');
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
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', startSegObserver);
    } else {
        startSegObserver();
    }

})();

// Temporary probe: confirms the script executed in the page's JS context.
// Removed in Task 12 along with __vizScriptLoaded.
setTimeout(function() {
    console.log('VIZ boot', !!window.MilkViz, window.__vizScriptLoaded === true);
}, 3000);
