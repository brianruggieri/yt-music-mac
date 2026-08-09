// Stream smoother: makes the Song<->Video mode toggle audibly seamless.
//
// YT tears the media element down on toggle (~250-450ms silence, upstream, measured
// identical in plain Chrome — see .claude/plans/seamless-mode-switch.md). Two modules
// mask it: an MSE audio BRIDGE that replays retained bytes of the outgoing stream
// across the gap, and a LOUDNESS layer that matches the two differently-mastered
// uploads' levels. Both are fail-silent: any error degrades to the (visually masked)
// gap, never broken playback.
//
// MUST inject at document START, main frame only: the fetch hook has to see the first
// /youtubei/v1/player call and the prototype patches must precede YT's player boot.
// Spec + review history: .claude/plans/seamless-mode-switch.md (4 codex rounds).
(function () {
    'use strict';
    if (!/(^|\.)music\.youtube\.com$/.test(location.hostname)) return;
    if (window.__streamSmoother) return;

    // Kill switches. Pre-seeded values win, and the pre-seeded OBJECT keeps its
    // identity — a caller holding the object it seeded can still flip switches.
    // A frozen/sealed seed must not throw the installer (strict mode): missing keys
    // then read undefined => that feature stays off, which is the fail-safe direction.
    var flags = window.__smootherFlags = window.__smootherFlags || {};
    try {
        if (!('bridge' in flags)) flags.bridge = true;
        if (!('loudness' in flags)) flags.loudness = true;
    } catch (e) {}

    // ---- telemetry ---------------------------------------------------------------
    function emit(module, event, detail) {
        try {
            document.dispatchEvent(new CustomEvent('ytm-smoother',
                { detail: Object.assign({ module: module, event: event, t: Math.round(performance.now()) }, detail || {}) }));
        } catch (e) {}
    }

    // ---- loudness metadata cache (fetch hook + cold-load seed) -------------------
    // videoId -> {loudnessDb, perceptualLoudnessDb, ts}. Looked up by videoId ONLY —
    // response arrival order is never treated as "active stream" identity.
    var loudnessCache = new Map();
    var LOUDNESS_CACHE_MAX = 20;

    function cacheLoudness(videoId, audioConfig) {
        if (!videoId || !audioConfig) return;
        if (typeof audioConfig.loudnessDb !== 'number' && typeof audioConfig.perceptualLoudnessDb !== 'number') return;
        loudnessCache.delete(videoId);                       // refresh LRU position
        loudnessCache.set(videoId, {
            loudnessDb: audioConfig.loudnessDb,
            perceptualLoudnessDb: audioConfig.perceptualLoudnessDb,
            ts: Date.now()
        });
        while (loudnessCache.size > LOUDNESS_CACHE_MAX) {
            loudnessCache.delete(loudnessCache.keys().next().value);
        }
        emit('loudness', 'cached', { videoId: videoId, loudnessDb: audioConfig.loudnessDb, perceptualLoudnessDb: audioConfig.perceptualLoudnessDb });
        if (flags.loudness) loudnessOnCached(videoId);        // staging hook (loudness module)
    }

    function harvestPlayerResponse(pr) {
        try {
            if (!pr) return;
            var vid = pr.videoDetails && pr.videoDetails.videoId;
            var ac = pr.playerConfig && pr.playerConfig.audioConfig;
            cacheLoudness(vid, ac);
        } catch (e) {}
    }

    var origFetch = window.fetch;
    window.fetch = function () {
        // Call-original-exactly-once: our work happens on the returned promise; the
        // original is invoked a single time and its result/throw passes through.
        var result = origFetch.apply(this, arguments);
        try {
            var url = arguments[0] && (typeof arguments[0] === 'string' ? arguments[0] : arguments[0].url);
            if (url && url.indexOf('/youtubei/v1/player') !== -1) {
                result.then(function (res) {
                    try { res.clone().json().then(harvestPlayerResponse, function () {}); } catch (e) {}
                }, function () {});
            }
        } catch (e) {}
        return result;
    };

    // YT Music on WebKit issues /youtubei/v1/player via XHR, not fetch (measured:
    // the fetch hook alone caught zero responses in-app). Same harvest, same
    // call-original-exactly-once discipline; the load listener is passive.
    if (typeof XMLHttpRequest !== 'undefined') {
        var origXhrOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
            try {
                if (typeof url === 'string' && url.indexOf('/youtubei/v1/player') !== -1 && !this.__smootherWatched) {
                    this.__smootherWatched = true;
                    this.addEventListener('load', function () {
                        try { harvestPlayerResponse(JSON.parse(this.responseText)); } catch (e) {}
                    });
                }
            } catch (e) {}
            return origXhrOpen.apply(this, arguments);
        };
    }

    // Cold-load track arrives embedded, not via fetch.
    function seedInitial() { harvestPlayerResponse(window.ytInitialPlayerResponse); }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', seedInitial);
    else seedInitial();

    // ---- MediaSource ownership map ----------------------------------------------
    // objectURL -> MediaSource lets us resolve WHICH MediaSource is attached to the
    // main <video> (video.src lookup) so preload/ad sources are never bridged.
    var urlToMediaSource = new Map();            // capped; entries die with src rotation
    var ownedMedia = new WeakSet();              // bridge-owned MediaSource/SourceBuffer/elements: excluded from capture

    var origCreateObjectURL = URL.createObjectURL;
    URL.createObjectURL = function (obj) {
        var url = origCreateObjectURL.apply(this, arguments);
        try {
            if (typeof MediaSource !== 'undefined' && obj instanceof MediaSource && !ownedMedia.has(obj)) {
                urlToMediaSource.set(url, obj);
                if (urlToMediaSource.size > 8) urlToMediaSource.delete(urlToMediaSource.keys().next().value);
            }
        } catch (e) {}
        return url;
    };

    // ---- audio byte retention (appendBuffer hook) --------------------------------
    // Per audio SourceBuffer: ordered committed append history (arbitrary chunks — no
    // segment parsing), pending copy until updateend commits it, replayability flag.
    // 8MB TOTAL live budget, stop-retaining semantics (never evict a group's head;
    // whole non-attached groups evicted first). See spec §hook-layer-4.
    var RETAIN_BUDGET = 8 * 1024 * 1024;
    var retainedTotal = 0;
    var buffers = new Map();                     // SourceBuffer -> state
    var mediaSourceBuffers = new WeakMap();      // MediaSource -> [SourceBuffer]

    function bufState(sb) { return buffers.get(sb); }

    function dropGroup(ms) {
        var list = mediaSourceBuffers.get(ms) || [];
        list.forEach(function (sb) {
            var st = buffers.get(sb);
            if (st) { retainedTotal -= st.bytes; buffers.delete(sb); }
        });
    }

    function attachedMediaSource(videoEl) {
        try { return videoEl && videoEl.src ? urlToMediaSource.get(videoEl.src) : null; } catch (e) { return null; }
    }

    function evictForBudget(needed, keepMs) {
        if (retainedTotal + needed <= RETAIN_BUDGET) return true;
        // Evict whole groups not attached to the main video, oldest first.
        var mainVideo = document.querySelector('video');
        var attached = attachedMediaSource(mainVideo);
        urlToMediaSource.forEach(function (ms) {
            if (retainedTotal + needed <= RETAIN_BUDGET) return;
            if (ms !== attached && ms !== keepMs) dropGroup(ms);
        });
        return retainedTotal + needed <= RETAIN_BUDGET;
    }

    var origAddSourceBuffer = MediaSource.prototype.addSourceBuffer;
    MediaSource.prototype.addSourceBuffer = function (mime) {
        var sb = origAddSourceBuffer.apply(this, arguments);
        try {
            if (ownedMedia.has(this)) { ownedMedia.add(sb); return sb; }
            var list = mediaSourceBuffers.get(this) || [];
            list.push(sb);
            mediaSourceBuffers.set(this, list);
            if (typeof mime === 'string' && mime.indexOf('audio/') === 0) {
                buffers.set(sb, {
                    mime: mime, ms: this, chunks: [], bytes: 0,
                    pending: null, replayable: true, lastAppendTs: 0
                });
                sb.addEventListener('updateend', function () {
                    var st = bufState(sb);
                    if (!st || !st.pending) return;
                    // Commit the pending copy: the append succeeded end-to-end.
                    if (evictForBudget(st.pending.byteLength, st.ms)) {
                        st.chunks.push(st.pending);
                        st.bytes += st.pending.byteLength;
                        retainedTotal += st.pending.byteLength;
                    } else if (st.bytes > 0) {
                        // Stop-retaining: keep committed head, mark tail-capped.
                        if (!st.capped) { st.capped = true; emit('retention', 'cap', { bytes: st.bytes }); }
                        st.replayable = st.replayable && true;   // history stays valid, just incomplete tail
                        st.tailIncomplete = true;
                    }
                    st.pending = null;
                });
                sb.addEventListener('error', function () {
                    var st = bufState(sb);
                    if (st) { st.pending = null; st.replayable = false; }
                });
            }
        } catch (e) {}
        return sb;
    };

    var origChangeType = SourceBuffer.prototype.changeType;
    if (origChangeType) {
        SourceBuffer.prototype.changeType = function (mime) {
            var r = origChangeType.apply(this, arguments);
            // Only after the native call succeeded: reset retention for this buffer.
            try {
                var st = bufState(this);
                if (st) {
                    retainedTotal -= st.bytes;
                    buffers.set(this, { mime: mime, ms: st.ms, chunks: [], bytes: 0, pending: null, replayable: true, lastAppendTs: 0 });
                }
            } catch (e) {}
            return r;
        };
    }

    var origAbort = SourceBuffer.prototype.abort;
    SourceBuffer.prototype.abort = function () {
        // Whether an append was in flight must be read BEFORE the native call clears it.
        var wasUpdating = false;
        try { wasUpdating = this.updating === true; } catch (e) {}
        var r = origAbort.apply(this, arguments);
        // abort() resets MSE parser state; bytes of an INTERRUPTED append are partially
        // consumed, so a concatenated replay across that boundary feeds the parser data
        // it discarded — invalidate. But YT also calls abort() routinely during normal
        // stream setup with the parser idle (measured: every toggle) — an idle abort
        // discards nothing, and invalidating there would disable bridging for every
        // stream. Residual risk (segment split across appends + idle abort) surfaces as
        // a decode error in the bridge's OWN element, which fail-silently tears down.
        try {
            var st = bufState(this);
            if (st) {
                st.pending = null;
                if (wasUpdating) { st.replayable = false; emit('retention', 'abort-nonreplayable', {}); }
            }
        } catch (e) {}
        return r;
    };

    var origAppendBuffer = SourceBuffer.prototype.appendBuffer;
    SourceBuffer.prototype.appendBuffer = function (data) {
        var st = null, copy = null, nonDefault = false;
        try {
            if (!ownedMedia.has(this)) {
                st = bufState(this);
                if (st && !st.capped) {
                    // Non-default append semantics change the resulting timeline in
                    // ways a plain byte replay can't reproduce — decline to bridge.
                    nonDefault = (this.timestampOffset !== 0) ||
                        (this.appendWindowStart !== 0) ||
                        (this.appendWindowEnd !== Infinity) ||
                        (this.mode === 'sequence');
                    var u8 = data instanceof ArrayBuffer ? new Uint8Array(data)
                        : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
                        : null;
                    if (u8) copy = u8.slice();
                }
            }
        } catch (e) { st = null; }
        var r = origAppendBuffer.apply(this, arguments);
        // Pending becomes visible only after the native call returned without throwing.
        try {
            if (st) {
                if (nonDefault) { st.replayable = false; }
                else if (copy) { st.pending = copy; st.lastAppendTs = performance.now(); }
            }
        } catch (e) {}
        return r;
    };

    // ---- playback position tracker -----------------------------------------------
    // Capture-phase document listeners reach media elements without bubbling and
    // survive element replacement. Estimate = lastCt + elapsed*rate while advancing.
    var pos = { lastCt: 0, wallTs: 0, rate: 1, advancing: false, el: null };
    function isMainVideo(t) { return t && t.tagName === 'VIDEO' && !ownedMedia.has(t); }
    document.addEventListener('timeupdate', function (e) {
        if (!isMainVideo(e.target)) return;
        pos.lastCt = e.target.currentTime; pos.wallTs = performance.now();
        pos.rate = e.target.playbackRate; pos.advancing = !e.target.paused; pos.el = e.target;
        // Steady playback outside a swap keeps the stable id fresh; captured at swapOut
        // so a click-time URL flip can't masquerade the NEW id as the OLD one.
        if (!swap.active) stableId = currentVideoId() || stableId;
    }, true);
    ['waiting', 'pause', 'seeking', 'emptied'].forEach(function (ev) {
        document.addEventListener(ev, function (e) {
            if (!isMainVideo(e.target)) return;
            if (pos.advancing) { pos.lastCt = estimatePos(); pos.wallTs = performance.now(); }
            pos.advancing = false;
        }, true);
    });
    ['playing', 'ratechange'].forEach(function (ev) {
        document.addEventListener(ev, function (e) {
            if (!isMainVideo(e.target)) return;
            pos.lastCt = e.target.currentTime; pos.wallTs = performance.now();
            pos.rate = e.target.playbackRate; pos.advancing = !e.target.paused;
        }, true);
    });
    function estimatePos() {
        return pos.lastCt + (pos.advancing ? (performance.now() - pos.wallTs) / 1000 * pos.rate : 0);
    }

    // ---- swap window state ---------------------------------------------------------
    // Armed by visualizer.js's ytm-swapfade {phase:'out'}; both modules key off it.
    // generation increments per swap; handoverSeen latches the qualified handover
    // (emptied observed, then playing with ct>0) so async continuations can bail.
    var swap = { generation: 0, active: false, emptiedSeen: false, handoverSeen: false, outTs: 0, oldId: null };
    var stableId = null;         // last videoId observed during steady (non-swap) playback

    function currentVideoId() {
        try { return new URLSearchParams(location.search).get('v'); } catch (e) { return null; }
    }

    document.addEventListener('ytm-swapfade', function (e) {
        if (!e.detail || e.detail.phase !== 'out') return;
        swap.generation++; swap.active = true; swap.emptiedSeen = false; swap.handoverSeen = false;
        swap.outTs = performance.now(); swap.oldId = stableId || currentVideoId();
        emit('swap', 'out', { generation: swap.generation, oldId: swap.oldId, pos: estimatePos() });
        onSwapOut(swap.generation);
    });
    document.addEventListener('emptied', function (e) {
        if (!isMainVideo(e.target)) return;
        if (swap.active) {
            if (!swap.emptiedSeen) {
                swap.emptiedSeen = true;
                onSwapEmptied(swap.generation, e.target);   // pre-audio boundary: loudness applies here, bridge start-latch opens
            }
        } else {
            onOutsideBoundary();                  // resource boundary outside a swap: compensation resets unconditionally
        }
    }, true);
    document.addEventListener('loadstart', function (e) {
        if (!isMainVideo(e.target) || swap.active) return;
        onOutsideBoundary();
    }, true);
    // Qualified handover: after the swap's `emptied`, the new stream is audibly live.
    // `playing` alone is NOT sufficient — YT may start at 0 and seek back afterward, in
    // which case the one `playing` fires at ct===0 and a single-shot latch would leave
    // the bridge doubling with the new stream until its hard timer. `timeupdate` with
    // ct>0 covers that ordering (bridge-review blocker).
    function maybeHandover(e) {
        if (!swap.active || !swap.emptiedSeen || swap.handoverSeen) return;
        if (!isMainVideo(e.target) || e.target.paused || !(e.target.currentTime > 0)) return;
        swap.handoverSeen = true; swap.active = false;
        emit('swap', 'handover', { generation: swap.generation, newId: currentVideoId() });
        onHandover(swap.generation, e.target);
    }
    document.addEventListener('playing', maybeHandover, true);
    document.addEventListener('timeupdate', maybeHandover, true);
    // Swap window safety valve: if no qualified handover within 5s, close the window.
    setInterval(function () {
        if (swap.active && performance.now() - swap.outTs > 5000) {
            swap.active = false;
            emit('swap', 'expired', { generation: swap.generation });
            onSwapExpired(swap.generation);
        }
    }, 1000);

    // ---- module slots ---------------------------------------------------------------
    // Implemented by the bridge and loudness modules below; foundation calls them.
    function onSwapOut(generation) {
        if (flags.bridge) bridgeOnSwapOut(generation);
        if (flags.loudness) loudnessOnSwapOut(generation);
    }
    function onSwapEmptied(generation, el) {
        if (flags.bridge) bridgeOnEmptied(generation);
        if (flags.loudness) loudnessOnEmptied(generation, el);
    }
    function onHandover(generation, videoEl) {
        if (flags.bridge) bridgeOnHandover(generation);
        if (flags.loudness) loudnessOnHandover(generation, videoEl);
    }
    function onSwapExpired(generation) {
        if (flags.bridge) bridgeOnHandover(generation);       // ramp/teardown path is shared
        if (flags.loudness) loudnessOnExpired(generation);
    }
    function onOutsideBoundary() {
        if (flags.loudness) loudnessOnOutsideBoundary();
    }

    // === MODULE: audio bridge =========================================================
    // The toggle tears the main element down, so for ~300ms nothing is decoding. We
    // replay the OUTGOING stream's own retained bytes through a hidden, owned <audio>
    // for exactly that gap — same bytes, same timeline position, same volume, so the
    // listener hears one continuous stream. Two hard rules, both audible if broken:
    // it never plays while the main element is still alive (two-input latch), and it
    // never survives the incoming stream's first audio (ramped handover).

    var bridgeTune = { hardMs: 2000, rampMs: 150, stepMs: 12, maxAppends: 3, posTolerance: 0.1, minRunway: 0.25 };
    var bridge = null;                          // at most one live bridge, ever

    // Most-recently-appended replayable audio retention for a MediaSource. Shared with
    // the probe surface below so the bridge and the probe can never disagree.
    function retentionForMediaSource(ms) {
        var list = mediaSourceBuffers.get(ms) || [];
        var best = null;
        list.forEach(function (sb) {
            var st = buffers.get(sb);
            if (st && st.replayable && st.bytes > 0 && (!best || st.lastAppendTs > best.lastAppendTs)) best = st;
        });
        return best;   // {mime, chunks, bytes, ...} or null
    }

    // Native effective volume: the loudness layer's accessor reports the value YT set,
    // not what the element actually carries, so mute/level decisions read underneath it.
    function nativeVolumeOf(el) {
        try { return nativeVolumeGet ? nativeVolumeGet.call(el) : el.volume; } catch (e) { return 0; }
    }

    function bridgeAbort(generation, reason, extra) {
        emit('bridge', 'abort', Object.assign({ generation: generation, reason: reason }, extra || {}));
    }

    // Idempotent: every exit path routes through here, including the ones that fire
    // while an async continuation is still queued.
    function bridgeTeardown(b) {
        try { if (b.rampTimer) clearInterval(b.rampTimer); } catch (e) {}
        try { if (b.hardTimer) clearTimeout(b.hardTimer); } catch (e) {}
        b.rampTimer = null; b.hardTimer = null;
        b.listeners.forEach(function (l) {
            try { l[0].removeEventListener(l[1], l[2], l[3]); } catch (e) {}
        });
        b.listeners = [];
        try { if (b.el) b.el.pause(); } catch (e) {}
        try { if (b.url) URL.revokeObjectURL(b.url); } catch (e) {}
        try { if (b.el && b.el.parentNode) b.el.parentNode.removeChild(b.el); } catch (e) {}
        if (bridge === b) bridge = null;
    }

    // Telemetry pairs with the 'start' emission: a bridge that made noise ends, one
    // that never did aborts. Reason always travels.
    function bridgeStop(b, reason) {
        if (!b || b.stopped) return;
        b.stopped = true;
        var started = b.started;
        bridgeTeardown(b);
        emit('bridge', started ? 'end' : 'abort', { generation: b.generation, reason: reason });
    }

    // Listeners are owned by the bridge instance so teardown can drop every one of
    // them — a leaked capture listener on the main element outlives the swap.
    function bridgeListen(b, target, type, fn, capture) {
        var wrapped = function (e) {
            try { fn(e); } catch (err) { bridgeStop(b, 'listener-threw'); }
        };
        try {
            target.addEventListener(type, wrapped, !!capture);
            b.listeners.push([target, type, wrapped, !!capture]);
        } catch (e) {}
    }

    // Byte-identical stream, just fewer appends: the per-chunk updateend round trip is
    // pure startup latency and we are racing a ~300ms gap.
    function bridgeConcat(chunks, maxParts) {
        var total = 0, i;
        for (i = 0; i < chunks.length; i++) total += chunks[i].byteLength;
        var target = Math.ceil(total / maxParts), parts = [], group = [], groupBytes = 0;
        function flush() {
            var out = new Uint8Array(groupBytes), off = 0;
            group.forEach(function (c) { out.set(c, off); off += c.byteLength; });
            parts.push(out); group = []; groupBytes = 0;
        }
        for (i = 0; i < chunks.length; i++) {
            group.push(chunks[i]); groupBytes += chunks[i].byteLength;
            // The last part absorbs the remainder rather than spilling into an extra one.
            if (groupBytes >= target && parts.length < maxParts - 1) flush();
        }
        if (groupBytes > 0) flush();
        return parts;
    }

    function bridgeCovers(sb, t) {
        try {
            var r = sb.buffered, tol = bridgeTune.posTolerance;
            for (var i = 0; i < r.length; i++) {
                // Needs actual runway ahead, not just membership: a capped retention
                // whose range ends at ~t would start a bridge with nothing to play and
                // sit silent until the hard timer.
                if (t >= r.start(i) - tol && t <= r.end(i) - bridgeTune.minRunway) return true;
            }
        } catch (e) {}
        return false;
    }

    // Two-input latch (replay ready AND the outgoing element has released its resources)
    // with a handover veto. Called from both inputs; whichever lands second starts us.
    function bridgeMaybeStart(b) {
        if (!b || b.stopped || b.started || bridge !== b) return;
        if (!b.replayReady || !swap.emptiedSeen || swap.handoverSeen) return;
        if (b.generation !== swap.generation) { bridgeStop(b, 'stale-generation'); return; }
        try {
            b.el.currentTime = b.trackedPos;
            var main = mainVideo();
            if (main && 'preservesPitch' in b.el) b.el.preservesPitch = main.preservesPitch;
            b.el.volume = b.volume;         // owned element: the accessor passes through natively
            b.playRequested = true;         // before play(): a handover during the pending promise must still tear down
            var p = b.el.play();
            emit('bridge', 'start', {
                generation: b.generation, trackedPos: b.trackedPos,
                latencyMs: Math.round(performance.now() - b.outTs), bytes: b.bytes
            });
            if (p && typeof p.then === 'function') {
                // `started` flips only when playback truly began — a rejected play()
                // must read as an ABORT in telemetry (a silent bridge is not a bridge).
                p.then(function () { b.started = true; },
                       function () { bridgeStop(b, 'play-rejected'); });
            } else {
                b.started = true;
            }
        } catch (e) {
            bridgeStop(b, 'start-failed');
        }
    }

    function bridgeOnSwapOut(generation) {
        try {
            // A new swap over a live bridge: instant teardown, no ramp. A brief hard cut
            // beats two generations of old audio overlapping (rapid double-toggle).
            if (bridge) bridgeStop(bridge, 'superseded');

            var v = mainVideo();
            if (!v) return bridgeAbort(generation, 'no-main-video');
            var ms = attachedMediaSource(v);
            if (!ms) return bridgeAbort(generation, 'no-attached-mediasource');
            var st = retentionForMediaSource(ms);
            if (!st) return bridgeAbort(generation, 'no-replayable-retention');
            if (v.muted) return bridgeAbort(generation, 'muted');
            var vol = nativeVolumeOf(v);
            if (!(vol > 0)) return bridgeAbort(generation, 'zero-volume');
            if (v.paused) return bridgeAbort(generation, 'paused');
            // paused === false but stalled means there is no audio to continue.
            if (!pos.advancing) return bridgeAbort(generation, 'not-advancing');
            if (v.playbackRate !== 1) return bridgeAbort(generation, 'playback-rate');
            if (document.querySelector('.ad-showing, ytmusic-player[ad-showing]')) return bridgeAbort(generation, 'ad-showing');

            var el = document.createElement('audio');
            var msrc = new MediaSource();
            // Owned BEFORE any hooked call touches them, or the foundation would capture
            // our own replay into retention and charge it against the byte budget.
            ownedMedia.add(el); ownedMedia.add(msrc);

            var b = bridge = {
                generation: generation, el: el, ms: msrc, sb: null, url: null,
                trackedPos: estimatePos(),          // snapshot: extrapolated, never click-time ct
                volume: vol,                        // frozen at capture; later volumechange is never mirrored
                bytes: st.bytes, outTs: performance.now(),
                replayReady: false, started: false, playRequested: false, stopped: false,
                rampTimer: null, hardTimer: null, listeners: []
            };

            b.hardTimer = setTimeout(function () { bridgeStop(b, 'hard-timeout'); }, bridgeTune.hardMs);

            // Live guards. The swap's own pause/emptied/seeking on the main element are
            // NOT teardown signals — only intent that makes the bridge wrong to hear.
            bridgeListen(b, document, 'volumechange', function (e) {
                if (!isMainVideo(e.target)) return;
                if (e.target.muted || !(nativeVolumeOf(e.target) > 0)) bridgeStop(b, 'main-muted');
            }, true);
            bridgeListen(b, document, 'ratechange', function (e) {
                if (!isMainVideo(e.target)) return;
                if (e.target.playbackRate !== 1) bridgeStop(b, 'main-ratechange');
            }, true);
            bridgeListen(b, window, 'pagehide', function () { bridgeStop(b, 'pagehide'); });
            bridgeListen(b, el, 'error', function () { bridgeStop(b, 'element-error'); });
            bridgeListen(b, msrc, 'sourceclose', function () { bridgeStop(b, 'sourceclose'); });

            bridgeListen(b, msrc, 'sourceopen', function () {
                if (bridge !== b || b.stopped) return;
                // The outgoing teardown may have abort()ed in the gap since swap-out —
                // a concatenated replay across that boundary feeds discarded bytes.
                if (!st.replayable) return bridgeStop(b, 'retention-invalidated');
                var sb;
                try { sb = msrc.addSourceBuffer(st.mime); } catch (e) { return bridgeStop(b, 'addsourcebuffer-failed'); }
                b.sb = sb;
                ownedMedia.add(sb);                 // the addSourceBuffer wrapper already did this; cheap and order-proof
                bridgeListen(b, sb, 'error', function () { bridgeStop(b, 'sourcebuffer-error'); });
                bridgeListen(b, el, 'ended', function () { bridgeStop(b, 'bridge-ended'); });

                var parts = bridgeConcat(st.chunks, bridgeTune.maxAppends), idx = 0;
                b.bytes = 0; parts.forEach(function (u8) { b.bytes += u8.byteLength; });
                function pump() {
                    try { sb.appendBuffer(parts[idx++]); }
                    catch (e) { bridgeStop(b, e && e.name === 'QuotaExceededError' ? 'quota-exceeded' : 'append-failed'); }
                }
                bridgeListen(b, sb, 'updateend', function () {
                    if (bridge !== b || b.stopped) return;
                    if (idx < parts.length) return pump();
                    // Default timestampOffset means the replay keeps the original timeline,
                    // so the tracked position must land inside it or we'd play the wrong audio.
                    if (!bridgeCovers(sb, b.trackedPos)) return bridgeStop(b, 'position-not-buffered');
                    b.replayReady = true;
                    bridgeMaybeStart(b);
                });
                if (parts.length) pump(); else bridgeStop(b, 'no-replay-bytes');
            });

            el.style.display = 'none';
            try { (document.body || document.documentElement).appendChild(el); } catch (e) {}
            b.url = URL.createObjectURL(msrc);
            el.src = b.url;
        } catch (e) {
            if (bridge) bridgeStop(bridge, 'swapout-threw');
            else bridgeAbort(generation, 'swapout-threw');
        }
    }

    // Second latch input: the outgoing element has released its resources, so anything
    // we play from here on cannot double with it.
    function bridgeOnEmptied(generation) {
        try {
            var b = bridge;
            if (!b || b.stopped || b.generation !== generation) return;
            bridgeMaybeStart(b);
        } catch (e) {}
    }

    // Qualified handover (or the foundation's expired-window sweep, same path): the new
    // stream is audible, so fade out under it. The overlap IS the crossfade.
    function bridgeOnHandover(generation) {
        try {
            var b = bridge;
            if (!b || b.stopped || b.generation !== generation) return;
            if (!b.started) return bridgeStop(b, 'handover-before-start');
            if (b.rampTimer) return;
            // Wall-clock ramp, not tick-count: occluded/backgrounded windows throttle
            // timers to ~1s, and a tick-counted ramp would then lose a 13s race against
            // the hard timer. Elapsed-time math degrades to "one late tick, then stop".
            var v0 = b.volume, rampT0 = performance.now();
            b.rampTimer = setInterval(function () {
                try {
                    var f = (performance.now() - rampT0) / bridgeTune.rampMs;
                    if (f >= 1) return bridgeStop(b, 'handover');
                    b.el.volume = Math.max(0, v0 * (1 - f));
                } catch (e) { bridgeStop(b, 'ramp-failed'); }
            }, bridgeTune.stepMs);
        } catch (e) {}
    }

    // === MODULE: loudness match =======================================================
    // ATV and OMV are independently mastered uploads, so the toggle steps the level. We
    // retarget the INCOMING stream to the outgoing one's level with an invisible gain
    // layer underneath YT's volume slider: the public `volume` accessor keeps reporting
    // the value YT set, while the element natively carries userVolume * comp.gain. No UI
    // jump, no persisted attenuation, no feedback loop, no base/comp entanglement.
    //
    // Gain is STAGED when the incoming /player response lands inside the swap window and
    // APPLIED at `emptied` — the last boundary guaranteed to precede audible audio
    // (`playing` is queued after audio may already be out). Every terminal path resets.

    var comp = { gain: 1, videoId: null, el: null };   // el = the element carrying the gain
    // Candidates are keyed by videoId — never "last response wins". A prefetch or ad
    // /player response landing inside the ~300ms window must not hijack the gain that
    // gets applied pre-audio (reviewer blocker #1): at apply time the candidate is
    // SELECTED by the videoId the swap actually navigated to.
    var candidates = new Map();   // videoId -> {generation, gain, L_old, L_new, deltaDb}
    var openSwap = null;          // {generation, oldId, oldEntry} while a swap window is open
    var GAIN_FLOOR = 0.25;        // ~-12dB; beyond this something is wrong — clamp, fail-safe

    // ---- volume accessor patch (installed lazily, once, by the first swap) ----------
    var volumePatched = false;
    var nativeVolumeGet = null, nativeVolumeSet = null;
    var userVolume = new WeakMap();          // element -> the value its owner believes it set

    function effectiveGain() { return flags.loudness ? comp.gain : 1; }

    function seedVolume(el) {
        // Unseen element: its native value IS the public value (nothing has written
        // compensation through us yet), so the seed can never make a readback jump.
        if (!userVolume.has(el)) userVolume.set(el, nativeVolumeGet.call(el));
        return userVolume.get(el);
    }

    function mainVideo() {
        try {
            var v = document.querySelector('video');
            return v && !ownedMedia.has(v) ? v : null;
        } catch (e) { return null; }
    }

    // Re-apply from STORED userVolume — never read-modify-write, which would fold the
    // previous compensation into the user's own value.
    function reapply(el) {
        try {
            if (!volumePatched || !el || ownedMedia.has(el)) return;
            nativeVolumeSet.call(el, seedVolume(el) * effectiveGain());
        } catch (e) {}
    }

    function installVolumePatch() {
        if (volumePatched) return;
        var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');
        if (!d || typeof d.get !== 'function' || typeof d.set !== 'function') return;
        nativeVolumeGet = d.get; nativeVolumeSet = d.set;
        // Install migration: seed everything that already exists before the descriptor
        // is replaced, so a readback can never jump or come back undefined.
        try {
            Array.prototype.forEach.call(document.querySelectorAll('video,audio'), function (el) {
                if (!ownedMedia.has(el)) userVolume.set(el, nativeVolumeGet.call(el));
            });
        } catch (e) {}
        Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
            configurable: true,
            enumerable: d.enumerable,
            get: function () {
                if (ownedMedia.has(this)) return nativeVolumeGet.call(this);   // bridge audio: untouched
                return seedVolume(this);
            },
            set: function (v) {
                if (ownedMedia.has(this)) { nativeVolumeSet.call(this, v); return; }
                seedVolume(this);
                var n = Number(v);
                // Out of range: hand the raw value to the native setter so its error
                // reproduces exactly, and commit nothing.
                if (!(n >= 0 && n <= 1)) { nativeVolumeSet.call(this, v); return; }
                nativeVolumeSet.call(this, n * effectiveGain());
                userVolume.set(this, n);      // committed only after the native write returned
            }
        });
        volumePatched = true;
        // One-way install: the patch stays, but the kill switch has to bite immediately
        // rather than waiting for the next volume write. Turning it OFF also clears all
        // compensation state — otherwise a stale gain survives (boundary resets are
        // flag-gated) and re-enabling would resurrect it on an unrelated stream.
        try {
            var on = flags.loudness;
            Object.defineProperty(flags, 'loudness', {
                configurable: true, enumerable: true,
                get: function () { return on; },
                set: function (v) {
                    on = v;
                    var carrier = comp.el || mainVideo();
                    if (!v) { comp.gain = 1; comp.videoId = null; comp.el = null; candidates.clear(); openSwap = null; }
                    reapply(carrier);
                }
            });
        } catch (e) {}
        emit('loudness', 'patch-installed', {});
    }

    // ---- compensation state --------------------------------------------------------
    function setComp(gain, videoId, el) {
        var prevEl = comp.el;
        var changed = comp.gain !== gain;
        comp.gain = gain;
        comp.videoId = videoId || null;
        var target = el || prevEl || mainVideo();
        comp.el = gain !== 1 ? target : null;
        if (changed) {
            // The element that CARRIED the old gain must be rewritten too, or a reset
            // aimed at querySelector('video') can leave the real carrier attenuated.
            if (prevEl && prevEl !== target) reapply(prevEl);
            reapply(target);
        }
    }

    // Pairwise field selection (reviewer #3): perceptualLoudnessDb and loudnessDb sit
    // on different reference scales, so a delta must come from the SAME field on both
    // sides — perceptual if both have it, else loudnessDb if both have it, else null.
    function pairLoudness(oldEntry, newEntry) {
        if (!oldEntry || !newEntry) return null;
        if (typeof oldEntry.perceptualLoudnessDb === 'number' && typeof newEntry.perceptualLoudnessDb === 'number') {
            return { L_old: oldEntry.perceptualLoudnessDb, L_new: newEntry.perceptualLoudnessDb };
        }
        if (typeof oldEntry.loudnessDb === 'number' && typeof newEntry.loudnessDb === 'number') {
            return { L_old: oldEntry.loudnessDb, L_new: newEntry.loudnessDb };
        }
        return null;
    }

    // Select the candidate for this generation. URL-first; when the URL hasn't
    // committed to the incoming id (SPA timing varies), an UNAMBIGUOUS single
    // candidate is safe to use — the prefetch-hijack case necessarily creates a
    // second candidate, and ambiguity always declines.
    function pickCandidate(generation) {
        var pick = currentVideoId();
        if (pick && openSwap && pick !== openSwap.oldId) {
            var c = candidates.get(pick);
            return (c && c.generation === generation) ? { id: pick, c: c } : null;
        }
        if (candidates.size === 1) {
            var id = candidates.keys().next().value;
            var c1 = candidates.get(id);
            return (c1.generation === generation) ? { id: id, c: c1 } : null;
        }
        return null;
    }

    function applyCandidate(c, videoId, el) {
        setComp(c.gain, videoId, el);
        emit('loudness', 'apply', {
            generation: c.generation, newId: videoId, L_old: c.L_old,
            L_new: c.L_new, deltaDb: c.deltaDb, gain: c.gain
        });
    }

    // ---- slots ---------------------------------------------------------------------
    function loudnessOnSwapOut(generation) {
        try {
            installVolumePatch();
            candidates.clear();
            var oldId = swap.oldId;
            openSwap = { generation: generation, oldId: oldId, oldEntry: oldId ? loudnessCache.get(oldId) : null };
            emit('loudness', 'armed', { generation: generation, oldId: oldId, hasOldMeta: !!openSwap.oldEntry });
        } catch (e) { candidates.clear(); openSwap = null; setComp(1, null); }
    }

    // Called from cacheLoudness: metadata may land any time inside the window. Every
    // response becomes a CANDIDATE keyed by videoId; only the videoId the swap actually
    // navigated to is ever applied (a prefetch/ad response cannot hijack the gain).
    function loudnessOnCached(videoId) {
        try {
            if (!openSwap || !swap.active || swap.generation !== openSwap.generation) return;
            if (!videoId || videoId === openSwap.oldId) return;
            var pair = pairLoudness(openSwap.oldEntry, loudnessCache.get(videoId));
            if (!pair) { emit('loudness', 'candidate-unusable', { generation: openSwap.generation, newId: videoId }); return; }
            // YT's own normalization is attenuate-only toward its reference, so a
            // stream's POST-normalization loudness is min(L, 0) — modelling it any other
            // way double-corrects. No boost path exists on the element, so an incoming
            // quieter stream stays as-is (documented residual dip).
            var deltaDb = Math.min(pair.L_new, 0) - Math.min(pair.L_old, 0);
            var gain = deltaDb > 0.5 ? Math.max(Math.pow(10, -deltaDb / 20), GAIN_FLOOR) : 1;
            candidates.set(videoId, {
                generation: openSwap.generation, gain: gain,
                L_old: pair.L_old, L_new: pair.L_new, deltaDb: deltaDb
            });
            emit('loudness', 'candidate', {
                generation: openSwap.generation, oldId: openSwap.oldId, newId: videoId,
                L_old: pair.L_old, L_new: pair.L_new, deltaDb: deltaDb, gain: gain
            });
            // Arrived past the pre-audio boundary: apply immediately if this candidate
            // is the (URL-confirmed or unambiguous) stream the player moved to.
            if (swap.emptiedSeen && !swap.handoverSeen) {
                var sel = pickCandidate(openSwap.generation);
                if (sel && sel.id === videoId) applyCandidate(sel.c, sel.id, openSwap.el || mainVideo());
            }
        } catch (e) {}
    }

    // THE apply point: resource teardown, guaranteed to precede any audio of the
    // incoming stream. `el` is the element that actually fired `emptied` — never a
    // querySelector guess (reviewer #4).
    function loudnessOnEmptied(generation, el) {
        try {
            setComp(1, null, el);                          // old compensation never crosses the boundary
            if (openSwap) openSwap.el = el;                // late-arrival applies target THIS element
            var sel = pickCandidate(generation);
            if (sel) applyCandidate(sel.c, sel.id, el);
            else emit('loudness', 'no-candidate-at-emptied', { generation: generation, urlId: currentVideoId(), nCandidates: candidates.size });
        } catch (e) { candidates.clear(); setComp(1, null, el); }
    }

    function loudnessOnHandover(generation, videoEl) {
        try {
            if (comp.videoId) {
                // Revalidate against the stream that actually arrived (codex r4 #5),
                // and re-assert the native write unconditionally — the element may have
                // been replaced since emptied and a gain-equality guard would skip the
                // write on the new element (reviewer #5).
                var expected = comp.videoId, actual = currentVideoId();
                if (actual && actual !== expected && actual !== (openSwap && openSwap.oldId)) {
                    setComp(1, null, videoEl);
                    emit('loudness', 'revalidate-reset', { generation: generation, expected: expected, actual: actual });
                } else {
                    if (videoEl) comp.el = videoEl;   // element may have been replaced since emptied
                    reapply(videoEl || comp.el);
                }
            } else {
                setComp(1, null, videoEl);
                emit('loudness', 'skip', { generation: generation, reason: 'nothing-applied' });
            }
            candidates.clear(); openSwap = null;
        } catch (e) { candidates.clear(); openSwap = null; setComp(1, null); }
    }

    function loudnessOnExpired(generation) {
        try {
            candidates.clear(); openSwap = null; setComp(1, null);
            emit('loudness', 'expired-reset', { generation: generation });
        } catch (e) {}
    }

    // Every media boundary outside a swap window: unconditional reset, no URL
    // correlation to get wrong. Compensation can never leak across streams.
    function loudnessOnOutsideBoundary() {
        try {
            var was = comp.gain;
            candidates.clear(); openSwap = null; setComp(1, null);
            if (was !== 1) emit('loudness', 'boundary-reset', { was: was });
        } catch (e) {}
    }

    // ---- shared internals exposed to the modules + probe ---------------------------
    window.__streamSmoother = {
        flags: flags,
        emit: emit,
        loudnessCache: loudnessCache,
        currentVideoId: currentVideoId,
        estimatePos: estimatePos,
        attachedMediaSource: function () { return attachedMediaSource(document.querySelector('video')); },
        retention: {
            forMediaSource: retentionForMediaSource,
            totalBytes: function () { return retainedTotal; }
        },
        bridgeTuning: bridgeTune,
        ownedMedia: ownedMedia,
        swapState: function () { return { generation: swap.generation, active: swap.active, handoverSeen: swap.handoverSeen }; }
    };

    emit('foundation', 'installed', {});
})();
