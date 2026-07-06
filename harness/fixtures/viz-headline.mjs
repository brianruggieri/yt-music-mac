// SIGNATURE HEADLINE marketing asset: the app's REAL now-playing page (sidebar, top bar,
// player bar, up-next queue) with the REAL 3-way Song/Video/Visualizer toggle set to
// "Visualizer", and a REAL animated Butterchurn playing in the media stage. Only the stage
// animates; the chrome is static — so the captured full-page frames ARE the finished
// composite (no compositing step). See fixtures/VISUALIZER-HEADLINE-RESEARCH.md.
//
// Reuses: installFixture + the light engine (real chrome), gotoPlayer (real player page +
// revealed 3-way toggle), and the exact Butterchurn+noise-audio pattern from screenshots.mjs.
// Butterchurn scripts are injected via addInitScript (page CSP blocks addScriptTag on the real
// music.youtube.com page — same document-start path the WKWebView app and visualizer.js use).
//
// Run: node fixtures/viz-headline.mjs   (npm run viz-headline)
import { webkit } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { loadEngineScript } from '../lib/engine.js';
import { installFixture } from './fixture.mjs';
import { gotoPlayer } from '../lib/player-mock.js';

const BASE = 'https://music.youtube.com';
const ENGINE = loadEngineScript();
const VIZ = new URL('../../youtube-music-player/Resources/visualizer/', import.meta.url);
const vf = (n) => fileURLToPath(new URL(n, VIZ));
const OUT = new URL('../../screenshots/', import.meta.url);
const out = (n) => fileURLToPath(new URL(n, OUT));

const FPS = 10;
const FRAMES = 40;            // ~4s loop
const WIDTH = 900;            // GIF/video output width
const PRESET = 'Flexi - infused with the spiral';

const frameDir = fs.mkdtempSync(path.join(os.tmpdir(), 'viz-headline-'));
const framePath = (i) => path.join(frameDir, `f-${String(i).padStart(4, '0')}.png`);
const notes = [];

const b = await webkit.launch();
try {
  const ctx = await b.newContext({
    storageState: process.env.YTM_AUTH || undefined,
    colorScheme: 'light',
    viewport: { width: 1312, height: 912 },
    deviceScaleFactor: 2,
  });
  await installFixture(ctx);
  // Strip the page CSP on the /watch HTML doc. YT ships `require-trusted-types-for 'script'`,
  // and this Playwright WebKit build ENFORCES trusted-types (the shipping WKWebView doesn't),
  // so Butterchurn 2.6.7's runtime equation eval throws. Removing the header restores the
  // app's effective behavior. Registered after installFixture so it runs first for the
  // document; everything else falls through to the fixture's handler.
  await ctx.route('**/*', async (route) => {
    if (route.request().resourceType() !== 'document') return route.fallback();
    const resp = await route.fetch();
    const headers = { ...resp.headers() };
    delete headers['content-security-policy'];
    delete headers['content-security-policy-report-only'];
    return route.fulfill({ response: resp, headers });
  });
  await ctx.addInitScript({ content: ENGINE });
  // Butterchurn engine + preset pack on window at document-start (before gotoPlayer navigates).
  await ctx.addInitScript({ content: fs.readFileSync(vf('butterchurn.min.js'), 'utf8') });
  await ctx.addInitScript({ content: fs.readFileSync(vf('butterchurnPresets.min.js'), 'utf8') });
  const p = await ctx.newPage();

  // Real player page with the revealed 3-way toggle (visualizer.js clones in the segment).
  await gotoPlayer(p, BASE);

  // Select the Visualizer segment and inject a real animated Butterchurn canvas into the stage.
  const started = await p.evaluate(async (presetName) => {
    document.getElementById('mock-stage')?.remove();
    const media = document.querySelector('ytmusic-player');
    if (!media) throw new Error('media stage (ytmusic-player) not found');
    media.style.position = 'relative';
    const host = document.createElement('div');
    host.id = 'mock-stage';
    host.style.cssText = 'position:absolute;inset:0;z-index:5;border-radius:10px;overflow:hidden;background:#000;';
    const canvas = document.createElement('canvas');
    canvas.style.cssText = 'display:block;width:100%;height:100%;';
    const r = media.getBoundingClientRect();
    const pr = window.devicePixelRatio || 1;
    canvas.width = Math.max(2, Math.round(r.width * pr));
    canvas.height = Math.max(2, Math.round(r.height * pr));
    host.appendChild(canvas);
    media.appendChild(host);

    const bc = window.butterchurn && (window.butterchurn.default || window.butterchurn);
    const bp = window.butterchurnPresets && (window.butterchurnPresets.default || window.butterchurnPresets);
    if (!bc || !bp) throw new Error('butterchurn not on window');
    const actx = new (window.AudioContext || window.webkitAudioContext)();
    try { await actx.resume(); } catch {}
    const buf = actx.createBuffer(1, actx.sampleRate * 2, actx.sampleRate);
    const d = buf.getChannelData(0);
    for (let j = 0; j < d.length; j++) d[j] = (Math.random() * 2 - 1) * 0.28;
    const srcN = actx.createBufferSource(); srcN.buffer = buf; srcN.loop = true;
    const gain = actx.createGain(); gain.gain.value = 0.5; srcN.connect(gain);
    const viz = bc.createVisualizer(actx, canvas, { width: canvas.width, height: canvas.height, pixelRatio: 1 });
    viz.connectAudio(gain); srcN.start();
    const presets = bp.getPresets();
    const name = presets[presetName] ? presetName : Object.keys(presets)[0];
    viz.loadPreset(presets[name], 0);
    window.__viz = viz;
    let n = 0; (function loop() { if (n++ > 100000) return; window.__viz.render(); requestAnimationFrame(loop); })();

    // Reflect "Visualizer" as the selected segment (class only — activating it for real would
    // spin up the app's own WebGL/audio path; we drive Butterchurn ourselves above).
    const av = document.querySelector('.av-toggle');
    if (av) {
      const song = av.querySelector('.song-button:not(#milkviz-seg-btn)');
      const video = av.querySelector('.video-button:not(#milkviz-seg-btn)');
      const seg = av.querySelector('#milkviz-seg-btn');
      [song, video, seg].forEach((btn) => { if (btn) btn.classList.toggle('milkviz-sel', btn === seg); });
    }
    return { w: canvas.width, h: canvas.height, hasSeg: !!document.querySelector('#milkviz-seg-btn') };
  }, PRESET);
  if (!started.hasSeg) notes.push('WARNING: #milkviz-seg-btn (Visualizer segment) missing — toggle may not show Visualizer');

  // Let the bloom warm up, then capture N full-viewport frames on a fixed cadence.
  await p.waitForTimeout(2500);
  for (let i = 0; i < FRAMES; i++) {
    await p.waitForTimeout(Math.round(1000 / FPS));
    await p.screenshot({ path: framePath(i) });
  }

  // Guard: a black/frozen canvas would mean Butterchurn never rendered. Compare two frames'
  // bytes — identical stage means no motion.
  const s0 = fs.statSync(framePath(0)).size;
  const sN = fs.statSync(framePath(FRAMES - 1)).size;
  if (s0 === sN) notes.push('WARNING: first and last frame identical size — visualizer may not be animating');

  // --- Encode (ffmpeg-only path; gifski/pngquant not installed) ---
  const inGlob = { framerate: String(FPS) };
  const palette = path.join(frameDir, 'palette.png');
  const rawGif = path.join(frameDir, 'raw.gif');
  const scale = `scale=${WIDTH}:-1:flags=lanczos`;
  const scaleEven = `scale=${WIDTH}:-2:flags=lanczos`;

  // GIF: shared palette from frame-diff (best on a mostly-static page) -> paletteuse -> gifsicle.
  // Use the FULL 256-color palette and a gentle gifsicle lossy: the visualizer is gold-dominant,
  // and dropping to 160 colors + --lossy=80 culled the less-frequent saturated tones (the reds in
  // the swirls + the pink/purple album thumbnails washed out to gold). 256 colors + --lossy=30
  // keeps them and only costs ~0.7 MB.
  execFileSync('ffmpeg', ['-y', '-framerate', inGlob.framerate, '-i', path.join(frameDir, 'f-%04d.png'),
    '-vf', `${scale},palettegen=stats_mode=diff:max_colors=256`, palette], { stdio: 'ignore' });
  execFileSync('ffmpeg', ['-y', '-framerate', inGlob.framerate, '-i', path.join(frameDir, 'f-%04d.png'), '-i', palette,
    '-lavfi', `${scale} [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle`, rawGif], { stdio: 'ignore' });
  execFileSync('gifsicle', ['-O3', '--lossy=30', rawGif, '-o', out('viz-headline.gif')], { stdio: 'ignore' });

  // Animated WebP (landing page; clean loop). img2webp has no scale flag (and this ffmpeg has no
  // libwebp encoder), so pre-scale the frames to WIDTH with ffmpeg first, else the webp embeds the
  // raw 2624px frames -> multi-MB.
  const sdir = path.join(frameDir, 'scaled');
  fs.mkdirSync(sdir, { recursive: true });
  execFileSync('ffmpeg', ['-y', '-framerate', inGlob.framerate, '-i', path.join(frameDir, 'f-%04d.png'),
    '-vf', scale, path.join(sdir, 's-%04d.png')], { stdio: 'ignore' });
  const webpFrames = fs.readdirSync(sdir).filter((f) => f.endsWith('.png')).sort().map((f) => path.join(sdir, f));
  execFileSync('img2webp', ['-loop', '0', '-d', String(Math.round(1000 / FPS)), '-lossy', '-m', '6', '-q', '60',
    ...webpFrames, '-o', out('viz-headline.webp')], { stdio: 'ignore' });

  // Muted looping MP4 (H.264, widest support) + WebM (VP9, smaller) for landing/App Store/social.
  execFileSync('ffmpeg', ['-y', '-framerate', inGlob.framerate, '-i', path.join(frameDir, 'f-%04d.png'),
    '-vf', scaleEven, '-c:v', 'libx264', '-crf', '24', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an',
    out('viz-headline.mp4')], { stdio: 'ignore' });
  execFileSync('ffmpeg', ['-y', '-framerate', inGlob.framerate, '-i', path.join(frameDir, 'f-%04d.png'),
    '-vf', scaleEven, '-c:v', 'libvpx-vp9', '-crf', '34', '-b:v', '0', '-an',
    out('viz-headline.webm')], { stdio: 'ignore' });

  console.log('\n=== viz-headline ===');
  for (const f of ['viz-headline.gif', 'viz-headline.webp', 'viz-headline.mp4', 'viz-headline.webm']) {
    const bytes = fs.statSync(out(f)).size;
    console.log(`  ${f}  ${(bytes / 1024 / 1024).toFixed(2)}MB (${bytes}B)`);
  }
  console.log(`\n  stage canvas: ${started.w}x${started.h}  |  frames: ${FRAMES} @ ${FPS}fps -> ${WIDTH}px`);
  if (notes.length) { console.log('\nnotes:'); for (const n of notes) console.log('  -', n); }
  else console.log('\nnotes: none');
} finally {
  await b.close();
  fs.rmSync(frameDir, { recursive: true, force: true });
}
