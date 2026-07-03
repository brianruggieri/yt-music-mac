// The defined coverage inventory: every screen we sweep, plus interaction openers
// for the modal/menu/popup surfaces that only exist after a click. Add entries here
// to expand coverage — this list IS the "do we have all screens defined?" answer.

export const BASE = 'https://music.youtube.com';

// Route-reachable screens (no interaction needed).
// Detail-page paths use PUBLIC entity IDs (from the gitignored captures) — under fixtures the
// browse route serves the fake detail fixture for ANY MPREb_/VL/UC browseId, so the specific
// ID only matters to the live canary.
export const SCREENS = [
  { name: 'home', path: '/' },
  { name: 'explore', path: '/explore' },
  { name: 'explore-moods', path: '/moods_and_genres' },
  { name: 'library', path: '/library' },
  { name: 'search', path: '/search?q=daft%20punk' },
  { name: 'album-detail', path: '/browse/MPREb_DYSzDJvUSDu' },
  { name: 'playlist-detail', path: '/playlist?list=PLL-QUKxvck0fMtxQ2aXuU_872TdKnEcLm' },
  { name: 'artist-detail', path: '/channel/UCRr1xG_2WIDs18a6cIiCxeA' },
  { name: 'podcasts', path: '/podcasts' },
  { name: 'search-empty', path: '/search?q=zzqxwvkjhgp0987xyz' },   // "No results" empty state
  // NOTE (un-gated): empty-LIBRARY state can't be fabricated (this account has content, no
  // empty-state renderer to fake); transient toasts/snackbars auto-dismiss and can't be
  // screenshotted deterministically. Both stay on manual QA.
];

// Interaction openers — each navigates somewhere, then opens a dynamic surface.
// `open(page)` should leave the modal/menu visible; `name` is used for the snapshot.
// These are the long tail (dialogs, menus, toasts) that route enumeration can't reach.
// Openers use short, explicit timeouts so a missing trigger (e.g. logged-out, or a
// DOM change) fails fast and the test skips, instead of auto-waiting to the test limit.
const T = { timeout: 5000 };

const POPUP = 'ytmusic-menu-popup-renderer, ytmusic-multi-page-menu-renderer, tp-yt-paper-listbox.ytmusic-menu-popup-renderer';

export const INTERACTIONS = [
  {
    name: 'track-context-menu',
    path: '/',
    async open(page) {
      await openTrackMenu(page);
    },
  },
  {
    name: 'account-menu',
    path: '/',
    async open(page) {
      // The avatar button (top-right). Its real label is "Open avatar menu"; keep the older
      // fallbacks for live/logged-out variants.
      const trigger = page.locator('button[aria-label="Open avatar menu" i], button[aria-label*="Account" i], ytmusic-nav-bar button:has(img)').first();
      await trigger.waitFor({ state: 'visible', ...T });
      await trigger.click(T);
      await page.locator(POPUP + ', tp-yt-iron-dropdown').first().waitFor({ state: 'visible', ...T });
    },
  },
  {
    name: 'sort-menu',
    path: '/library',
    async open(page) {
      await page.locator('ytmusic-sort-filter-button-renderer, [aria-label*="Sort" i]').first().click(T);
      await page.locator(POPUP + ', tp-yt-iron-dropdown').first().waitFor({ state: 'visible', ...T });
    },
  },
  {
    name: 'add-to-playlist',
    path: '/',
    async open(page) {
      await openTrackMenu(page);
      await page.locator('ytmusic-menu-popup-renderer tp-yt-paper-item, ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer, ytmusic-menu-popup-renderer ytmusic-menu-navigation-item-renderer')
        .filter({ hasText: 'Save to playlist' }).first().click(T);
      await page.locator('ytmusic-add-to-playlist-renderer').first().waitFor({ state: 'visible', ...T });
    },
  },
  {
    name: 'settings',
    path: '/settings',
    async open(page) {
      // /settings renders as an overlay page (fed by account/get_setting) — nothing to
      // click, just wait for the settings surface to be up.
      await page.locator('ytmusic-settings-page').first().waitFor({ state: 'visible', ...T });
    },
  },
  {
    name: 'share-panel',
    path: '/',
    async open(page) {
      await openTrackMenu(page);
      await page.locator('ytmusic-menu-popup-renderer tp-yt-paper-item, ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer, ytmusic-menu-popup-renderer ytmusic-menu-navigation-item-renderer')
        .filter({ hasText: 'Share' }).first().click(T);
      await page.locator('yt-copy-link-renderer, ytmusic-unified-share-panel-renderer').first().waitFor({ state: 'visible', ...T });
    },
  },
  // NOTE: the in-webview image-cropper dialog (yt-image-editor-renderer, a Polymer +
  // <canvas> paper-dialog) does not lay out in headless WebKit — it attaches but never
  // renders, so a screenshot/contrast gate would test the page behind it. It also can't be
  // rendered from a static DOM fixture (needs YT's full Polymer runtime). The engine DOES
  // theme it (LightThemeEngine cropper block, confirmed in manual QA); like the native macOS
  // chrome it stays on manual QA. Left un-gated on purpose rather than shipping a false pass.
  {
    name: 'player-page',
    path: '/',
    async open(page) { await openPlayerPage(page); },
  },
  // NOTE: the player LYRICS and RELATED tabs fetch per-track via browse(MPLY…/MPTR…), but that
  // in-SPA fetch isn't reliably intercepted by the fixture route (real, copyrighted lyrics leak
  // into the render), so they're left un-gated rather than baselined with real content. The
  // player page's Up-Next/queue + the Song/Video toggle ARE covered by `player-page` above.
];

// Shared: start playback (click a track) and expand to the full now-playing player page.
async function openPlayerPage(page) {
  const row = page.locator('ytmusic-shelf-renderer ytmusic-responsive-list-item-renderer, ytmusic-carousel-shelf-renderer ytmusic-responsive-list-item-renderer')
    .filter({ visible: true }).first();
  await row.scrollIntoViewIfNeeded(T);
  await row.click(T);
  await page.waitForFunction(() => {
    const t = document.querySelector('ytmusic-player-bar .content-info-wrapper .title');
    return t && t.textContent.trim().length > 0;
  }, null, { timeout: 15_000 });
  const triggers = page.locator('ytmusic-player-bar .toggle-player-page-button, ytmusic-player-bar button[aria-label*="player page" i], ytmusic-player-bar .expand-button, ytmusic-player-bar img.image');
  const n = await triggers.count();
  for (let i = 0; i < n; i++) {
    const t = triggers.nth(i);
    if (await t.isVisible().catch(() => false)) { await t.click({ force: true, ...T }); break; }
  }
  await page.locator('ytmusic-player-page').first().waitFor({ state: 'visible', ...T });
  await page.locator('ytmusic-player-queue-item, ytmusic-player-queue ytmusic-playlist-panel-video-renderer, ytmusic-playlist-panel-video-renderer').first()
    .waitFor({ state: 'visible', ...T }).catch(() => {});
  await page.waitForTimeout(800);
}

// Shared: hover a visible shelf track row and open its ⋮ Action menu (used by the
// context-menu test and the dialogs that live behind it).
async function openTrackMenu(page) {
  const item = page.locator('ytmusic-shelf-renderer ytmusic-responsive-list-item-renderer, ytmusic-carousel-shelf-renderer ytmusic-responsive-list-item-renderer')
    .filter({ has: page.locator('button[aria-label="Action menu" i]'), visible: true }).first();
  await item.scrollIntoViewIfNeeded(T);
  await item.hover(T);
  await page.waitForTimeout(300);
  await item.locator('button[aria-label="Action menu" i]').click({ force: true, ...T });
  await page.locator('ytmusic-menu-popup-renderer').first().waitFor({ state: 'visible', ...T });
}
