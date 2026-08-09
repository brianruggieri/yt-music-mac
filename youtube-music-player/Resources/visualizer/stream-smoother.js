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

    // Kill switches. Pre-seeded values win (probe A/B seeds all-off then enables).
    var flags = window.__smootherFlags = Object.assign({ bridge: true, loudness: true }, window.__smootherFlags);

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
        var r = origAbort.apply(this, arguments);
        // Only after native success: abort resets MSE parser state mid-segment, so a
        // concatenated replay of committed bytes would feed the parser data it
        // discarded. Conservative: drop pending, mark non-replayable until changeType
        // or a fresh SourceBuffer. (Seek-adjacent bridging is an accepted limitation.)
        try {
            var st = bufState(this);
            if (st) { st.pending = null; st.replayable = false; emit('retention', 'abort-nonreplayable', {}); }
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

    function currentVideoId() {
        try { return new URLSearchParams(location.search).get('v'); } catch (e) { return null; }
    }

    document.addEventListener('ytm-swapfade', function (e) {
        if (!e.detail || e.detail.phase !== 'out') return;
        swap.generation++; swap.active = true; swap.emptiedSeen = false; swap.handoverSeen = false;
        swap.outTs = performance.now(); swap.oldId = currentVideoId();
        emit('swap', 'out', { generation: swap.generation, oldId: swap.oldId, pos: estimatePos() });
        onSwapOut(swap.generation);
    });
    document.addEventListener('emptied', function (e) {
        if (!isMainVideo(e.target)) return;
        if (swap.active) {
            if (!swap.emptiedSeen) {
                swap.emptiedSeen = true;
                onSwapEmptied(swap.generation);   // pre-audio boundary: loudness applies here, bridge start-latch opens
            }
        } else {
            onOutsideBoundary();                  // resource boundary outside a swap: compensation resets unconditionally
        }
    }, true);
    document.addEventListener('loadstart', function (e) {
        if (!isMainVideo(e.target) || swap.active) return;
        onOutsideBoundary();
    }, true);
    document.addEventListener('playing', function (e) {
        if (!swap.active || !swap.emptiedSeen || swap.handoverSeen) return;
        if (!isMainVideo(e.target) || !(e.target.currentTime > 0)) return;
        swap.handoverSeen = true; swap.active = false;
        emit('swap', 'handover', { generation: swap.generation, newId: currentVideoId() });
        onHandover(swap.generation, e.target);
    }, true);
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
    function onSwapEmptied(generation) {
        if (flags.bridge) bridgeOnEmptied(generation);
        if (flags.loudness) loudnessOnEmptied(generation);
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

    // === MODULE: audio bridge (implemented in bridge commit) =========================
    function bridgeOnSwapOut(generation) { /* slot */ }
    function bridgeOnEmptied(generation) { /* slot */ }
    function bridgeOnHandover(generation) { /* slot */ }

    // === MODULE: loudness match (implemented in loudness commit) =====================
    function loudnessOnSwapOut(generation) { /* slot */ }
    function loudnessOnEmptied(generation) { /* slot */ }
    function loudnessOnHandover(generation, videoEl) { /* slot */ }
    function loudnessOnExpired(generation) { /* slot */ }
    function loudnessOnOutsideBoundary() { /* slot */ }

    // ---- shared internals exposed to the modules + probe ---------------------------
    window.__streamSmoother = {
        flags: flags,
        emit: emit,
        loudnessCache: loudnessCache,
        currentVideoId: currentVideoId,
        estimatePos: estimatePos,
        attachedMediaSource: function () { return attachedMediaSource(document.querySelector('video')); },
        retention: {
            forMediaSource: function (ms) {
                var list = mediaSourceBuffers.get(ms) || [];
                var best = null;
                list.forEach(function (sb) {
                    var st = buffers.get(sb);
                    if (st && st.replayable && st.bytes > 0 && (!best || st.lastAppendTs > best.lastAppendTs)) best = st;
                });
                return best;   // {mime, chunks, bytes, ...} or null
            },
            totalBytes: function () { return retainedTotal; }
        },
        ownedMedia: ownedMedia,
        swapState: function () { return { generation: swap.generation, active: swap.active, handoverSeen: swap.handoverSeen }; }
    };

    emit('foundation', 'installed', {});
})();
