// Shared mock for the 3 now-playing states (album art / video / visualizer). The harness can't
// render real playback, video, or the native visualizer, so we open the real player page and
// inject deterministic fixture media into the media stage. Used by BOTH the marketing generator
// (fixtures/screenshots.mjs) and the regression suite (screens.js), so the two stay in sync.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const A = new URL('../fixtures/assets/', import.meta.url);
const uri = (rel) => 'data:image/jpeg;base64,' + fs.readFileSync(fileURLToPath(new URL(rel, A))).toString('base64');

// song = blurred-bg + centered square cover; video/visualizer = cover-fill. The visualizer uses
// a FIXED still (viz-still.jpg), not the regenerating screenshots/visualizer.png, so regression
// baselines stay deterministic.
const MEDIA = {
  'player-song': { src: uri('album/paper-lanterns.jpg'), mode: 'album' },
  'player-video': { src: uri('video/paper-lanterns.jpg'), mode: 'cover' },
  'player-visualizer': { src: uri('viz-still.jpg'), mode: 'cover' },
};
export const PLAYER_STATES = Object.keys(MEDIA);

// Navigate to the player page and hide the ad/upsell/toast chrome YT surfaces on /watch.
export async function gotoPlayer(page, base) {
  await page.goto(base + '/watch?v=dQw4w9WgXcQ', { waitUntil: 'commit' });
  await page.waitForFunction(() => {
    const t = document.querySelector('ytmusic-player-bar .content-info-wrapper .title');
    return t && t.textContent.trim().length > 0;
  }, { timeout: 15000 }).catch(() => {});
  await page.locator('ytmusic-player-page').first().waitFor({ state: 'visible', timeout: 8000 });
  await page.addStyleTag({
    content: `ytmusic-mealbar-promo-renderer, ytmusic-you-there-renderer, tp-yt-paper-toast,
      ytmusic-notification-action-renderer, yt-notification-action-renderer, ytmusic-popup-container,
      ytmusic-banner-promo-renderer, .ytp-ad-module { display: none !important; }`,
  }).catch(() => {});
  await page.waitForTimeout(1500);
}

// Inject the mock media for `state` into the player's media stage (append INTO the media element
// so it's transform-proof; no toggle click, which would load a real video ad).
export async function injectPlayerMedia(page, state) {
  await page.evaluate((m) => {
    document.getElementById('mock-stage')?.remove();
    const media = document.querySelector('ytmusic-player');
    if (!media) return;
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
  }, MEDIA[state]);
  await page.waitForTimeout(500);
}
