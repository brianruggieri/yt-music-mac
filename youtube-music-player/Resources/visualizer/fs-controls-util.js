// Pure, DOM-free control logic for the fullscreen visualizer bar + idle auto-hide.
// Injected before visualizer.js as window.MilkVizCtl. Kept DOM-free so it unit-tests in
// Node (harness/tests/fs-controls-util.spec.js) without a browser.
(function (root) {
    'use strict';

    // Idle auto-hide state machine. No DOM: the caller wires onShow/onHide to a surface and
    // feeds it activity()/setLock(). Timers injectable so tests drive them deterministically.
    function createIdleController(opts) {
        opts = opts || {};
        var timeout = opts.timeout != null ? opts.timeout : 2500;
        var threshold = opts.threshold != null ? opts.threshold : 8;
        var grace = opts.grace != null ? opts.grace : 500;
        var onShow = opts.onShow || function () {};
        var onHide = opts.onHide || function () {};
        var setTimer = opts.setTimer || setTimeout;
        var clearTimer = opts.clearTimer || clearTimeout;

        var lastX = null, lastY = null;
        var locks = { hover: false, focus: false, scrub: false };
        var hideTimer = null, graceTimer = null;
        var justHidden = false, visible = false;

        function anyLock() { return locks.hover || locks.focus || locks.scrub; }

        function armHide() {
            if (hideTimer !== null) { clearTimer(hideTimer); hideTimer = null; }
            if (anyLock()) return;
            hideTimer = setTimer(doHide, timeout);
        }

        function doHide() {
            hideTimer = null;
            if (anyLock()) return;
            visible = false;
            onHide();
            justHidden = true;  // suppress the synthetic mousemove that fullscreen/reflow fires
            if (graceTimer !== null) clearTimer(graceTimer);
            graceTimer = setTimer(function () { justHidden = false; graceTimer = null; }, grace);
        }

        // Show + (re)arm. Bypasses the justHidden guard: an intentional pointerdown/key/focus
        // must reveal even inside the post-hide grace window.
        function reveal() {
            if (!visible) { visible = true; onShow(); }
            armHide();
        }

        // Positional activity (mousemove). During the grace window, swallow moves (even large
        // synthetic jumps) but keep tracking position; otherwise ignore sub-threshold jitter.
        function activity(x, y) {
            if (justHidden) { lastX = x; lastY = y; return; }
            if (lastX !== null) {
                var dx = x - lastX, dy = y - lastY;
                if (dx * dx + dy * dy < threshold * threshold) return;
            }
            lastX = x; lastY = y;
            reveal();
        }

        function setLock(name, val) {
            if (!(name in locks)) return;
            locks[name] = !!val;
            if (val) { if (hideTimer !== null) { clearTimer(hideTimer); hideTimer = null; } }
            else if (!anyLock()) { armHide(); }
        }

        function destroy() {
            if (hideTimer !== null) { clearTimer(hideTimer); hideTimer = null; }
            if (graceTimer !== null) { clearTimer(graceTimer); graceTimer = null; }
            locks.hover = locks.focus = locks.scrub = false;
            justHidden = false;
        }

        return { activity: activity, reveal: reveal, setLock: setLock, destroy: destroy,
                 isVisible: function () { return visible; } };
    }

    // "M:SS" (or "H:MM:SS" past an hour). NaN/Infinity/negative -> "0:00".
    function formatTime(sec) {
        if (!isFinite(sec) || sec < 0) sec = 0;
        sec = Math.floor(sec);
        var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
        var mm = (h > 0 && m < 10) ? '0' + m : '' + m;
        var ss = s < 10 ? '0' + s : '' + s;
        return h > 0 ? h + ':' + mm + ':' + ss : mm + ':' + ss;
    }

    // Clamp a seek target into [0, duration]. Invalid duration -> null (caller disables seek).
    function clampSeek(t, duration) {
        if (!isFinite(duration) || duration <= 0) return null;
        if (!isFinite(t) || t < 0) return 0;
        return t > duration ? duration : t;
    }

    // Pick the active media element: prefer a playing one; else the longest one; else null.
    // "Valid" = finite positive duration AND readyState >= 1 (HAVE_METADATA) — this excludes
    // detached/ad/preload elements that have no loaded media yet. (readyState may be undefined
    // for plain test doubles; treat undefined as valid so pure tests can omit it.)
    function pickActiveVideo(videos) {
        var list = videos ? Array.prototype.slice.call(videos) : [];
        var valid = list.filter(function (v) {
            return v && isFinite(v.duration) && v.duration > 0 &&
                   (v.readyState === undefined || v.readyState >= 1);
        });
        if (!valid.length) return null;
        var playing = valid.filter(function (v) { return !v.paused && !v.ended; });
        var pool = playing.length ? playing : valid;
        return pool.reduce(function (best, v) { return (best && best.duration >= v.duration) ? best : v; }, null);
    }

    root.MilkVizCtl = { createIdleController: createIdleController, formatTime: formatTime,
                        clampSeek: clampSeek, pickActiveVideo: pickActiveVideo };
})(typeof self !== 'undefined' ? self : this);
