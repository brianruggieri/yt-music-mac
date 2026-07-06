// Shared mock for the 3 now-playing states (album art / video / visualizer). The harness can't
// render real playback (the fixture transform strips streamingData — it embeds the capturing
// machine's real IP — so YT's player never mounts real media). So we open the real player page,
// load the app's REAL toggle/visualizer script for authentic chrome, and inject deterministic
// fixture media into the real media stage — only the pixel BYTES are faked, not the styling.
// Used by BOTH the marketing generator (fixtures/screenshots.mjs) and the regression suite
// (screens.js), so the two stay in sync.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const A = new URL('../fixtures/assets/', import.meta.url);
const uri = (rel) => 'data:image/jpeg;base64,' + fs.readFileSync(fileURLToPath(new URL(rel, A))).toString('base64');

// The app's actual visualizer script — the single source of the 3-way Song/Video/Visualizer
// toggle (it clones YT's real Video button into a "Visualizer" segment and applies the real
// `.milkviz-styled` pill CSS). Loading THIS, not a hand-rolled toggle, is why the snapshot shows
// the real control. Its heavy WebGL/audio path only runs on activation, which we never trigger,
// so loading it just boots the toggle observer.
const VIZ_SCRIPT = fs.readFileSync(
  fileURLToPath(new URL('../../youtube-music-player/Resources/visualizer/visualizer.js', import.meta.url)), 'utf8');

// song = blurred-bg + centered square cover; video/visualizer = cover-fill. The visualizer uses
// a FIXED still (viz-still.jpg), not the regenerating screenshots/visualizer.png, so regression
// baselines stay deterministic. `seg` = which toggle segment reads selected for this state.
const MEDIA = {
  'player-song': { src: uri('album/paper-lanterns.jpg'), mode: 'album', seg: 'song' },
  'player-video': { src: uri('video/paper-lanterns.jpg'), mode: 'cover', seg: 'video' },
  'player-visualizer': { src: uri('viz-still.jpg'), mode: 'cover', seg: 'visualizer' },
};
export const PLAYER_STATES = Object.keys(MEDIA);

// Seed the real visualizer script (+ its support flag) so the app's actual 3-way toggle injects.
// MUST run before the /watch navigation: the script self-boots off DOMContentLoaded and a
// MutationObserver, and page CSP (require-trusted-types-for 'script') blocks addScriptTag, so
// addInitScript is the only path — the same document-start injection the WKWebView app uses.
export async function installVisualizer(page) {
  await page.addInitScript({ content: 'window.__ytmVizSupported = true;' });
  await page.addInitScript({ content: VIZ_SCRIPT });
}

// Navigate to the player page and hide the ad/upsell/toast chrome YT surfaces on /watch.
export async function gotoPlayer(page, base) {
  await installVisualizer(page);
  await page.goto(base + '/watch?v=dQw4w9WgXcQ', { waitUntil: 'commit' });
  // No .catch here: if /watch stops seeding playback (fixture / YT DOM change) the title
  // never populates — throw so the caller's skip/note path surfaces the broken fixture
  // instead of baselining an unseeded page.
  await page.waitForFunction(() => {
    const t = document.querySelector('ytmusic-player-bar .content-info-wrapper .title');
    return t && t.textContent.trim().length > 0;
  }, { timeout: 15000 });
  await page.locator('ytmusic-player-page').first().waitFor({ state: 'visible', timeout: 8000 });
  await page.addStyleTag({
    content: `ytmusic-mealbar-promo-renderer, ytmusic-you-there-renderer, tp-yt-paper-toast,
      ytmusic-notification-action-renderer, yt-notification-action-renderer, ytmusic-popup-container,
      ytmusic-banner-promo-renderer, .ytp-ad-module { display: none !important; }`,
  }).catch(() => {});
  // Reveal the real Song/Video/Visualizer toggle. YT collapses it with no video: the buttons
  // exist inside `.av-toggle`, but their wrapper `div.av` is display:none and the host carries
  // `toggle-disabled` (dimmed). Un-hide the wrapper + un-disable the host — the wrapper already
  // sits top-center of the media column, exactly where the real app shows it. visualizer.js's
  // observer then clones in the "Visualizer" segment.
  await page.evaluate(() => {
    const host = document.querySelector('ytmusic-av-toggle');
    if (!host) return;
    // Do NOT touch playback-mode: switching it to a video mode makes YT drop the (empty) audio
    // stage and collapse ytmusic-player to 0px. The Song/Video buttons already exist inside
    // `.av-toggle` regardless of mode; the toggle is hidden only because its wrapper `div.av` is
    // display:none. Reveal the wrapper (floated OUT of flow so it can't steal the stage's flex
    // space) and lift the disabled dimming — the buttons stay, the stage keeps its size.
    const wrap = host.closest('.av') || host.parentElement;
    const col = wrap && wrap.parentElement;
    if (col) col.style.setProperty('position', 'relative', 'important');
    if (wrap) {
      wrap.style.cssText += ';display:flex !important;justify-content:center !important;position:absolute !important;top:12px !important;left:0 !important;right:0 !important;z-index:10 !important;';
    }
    const av = document.querySelector('.av-toggle');
    if (av) av.style.setProperty('opacity', '1', 'important');
  });
  // Let visualizer.js inject its segment (observer-driven).
  await page.waitForSelector('#milkviz-seg-btn', { timeout: 5000 }).catch(() => {});
  await page.waitForTimeout(1500);
}

// Inject the mock media for `state` into the player's media stage (append INTO the media element
// so it's transform-proof; no toggle click, which would load a real video ad).
export async function injectPlayerMedia(page, state) {
  await page.evaluate(async (m) => {
    document.getElementById('mock-stage')?.remove();
    const media = document.querySelector('ytmusic-player');
    // Fail LOUD if the stage is gone (a YT DOM change) — a silent return would let the
    // marketing generator / regression suite capture an un-mocked stage and bake it into a
    // "passing" baseline. Callers surface the throw (test skip / generator note).
    if (!media) throw new Error('injectPlayerMedia: player media stage (ytmusic-player) not found');
    media.style.position = 'relative';
    const host = document.createElement('div');
    host.id = 'mock-stage';
    host.style.cssText = 'position:absolute;inset:0;z-index:5;border-radius:10px;overflow:hidden;background:#0a0a0a;';
    if (m.mode === 'album') {
      const bg = document.createElement('img'); bg.src = m.src;
      bg.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;object-fit:cover;filter:blur(28px) brightness(.55);transform:scale(1.1);';
      const fg = document.createElement('img'); fg.src = m.src;
      fg.style.cssText = 'position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);height:88%;aspect-ratio:1;object-fit:cover;border-radius:8px;box-shadow:0 10px 40px rgba(0,0,0,.5);';
      host.appendChild(bg); host.appendChild(fg);
    } else {
      const img = document.createElement('img'); img.src = m.src;
      img.style.cssText = 'width:100%;height:100%;object-fit:cover;display:block;';
      host.appendChild(img);
    }
    media.appendChild(host);
    // Wait for the injected images to actually load + decode before returning, so the
    // screenshot can't capture a blank/partial stage under load (the fixed timeout below is
    // just a paint settle, not the load guarantee). REJECT on load/decode failure — a broken
    // fixture image must surface, not silently baseline a blank stage. Handlers are attached
    // before the complete-check to avoid a load-before-attach race.
    await Promise.all([...host.querySelectorAll('img')].map((img) => new Promise((resolve, reject) => {
      const ok = () => (img.decode ? img.decode().then(resolve, reject) : resolve());
      img.onload = ok;
      img.onerror = () => reject(new Error('injectPlayerMedia: mock image failed to load'));
      if (img.complete && img.naturalWidth > 0) ok();
    })));
  }, MEDIA[state]);

  // Reflect the state in the toggle: highlight the matching segment (Song/Video/Visualizer).
  // For song/video we set aria-pressed and let visualizer.js's syncSegState pick it. For the
  // visualizer segment we set `.milkviz-sel` directly (activating it for real would spin up the
  // WebGL path we deliberately don't run); we avoid touching song/video aria there so the aria
  // observer doesn't fire and revert us. Static fixture = no track change re-asserts selection.
  await page.evaluate((seg) => {
    const av = document.querySelector('.av-toggle'); if (!av) return;
    const song = av.querySelector('.song-button:not(#milkviz-seg-btn)');
    const video = av.querySelector('.video-button:not(#milkviz-seg-btn)');
    const viz = av.querySelector('#milkviz-seg-btn');
    const target = seg === 'song' ? song : seg === 'video' ? video : viz;
    // song/video: set aria-pressed and let syncSegState pick it. visualizer: set ONLY the class
    // (touching the seg's aria fires the observer, which with _active=false reverts to Song). The
    // class is the last write and nothing re-syncs without an aria mutation, so it holds.
    if (seg === 'song' && song) song.setAttribute('aria-pressed', 'true');
    else if (seg === 'video' && video) video.setAttribute('aria-pressed', 'true');
    [song, video, viz].forEach((b) => { if (b) b.classList.toggle('milkviz-sel', b === target); });
  }, MEDIA[state].seg);
  await page.waitForTimeout(400);
}
