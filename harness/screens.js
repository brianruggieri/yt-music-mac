// The defined coverage inventory: every screen we sweep, plus interaction openers
// for the modal/menu/popup surfaces that only exist after a click. Add entries here
// to expand coverage — this list IS the "do we have all screens defined?" answer.

export const BASE = 'https://music.youtube.com';

// Route-reachable screens (no interaction needed).
export const SCREENS = [
  { name: 'home', path: '/' },
  { name: 'explore', path: '/explore' },
  { name: 'explore-moods', path: '/moods_and_genres' },
  { name: 'library', path: '/library' },
  { name: 'search', path: '/search?q=daft%20punk' },
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
      // pick a real track ROW (one that actually has an Action menu), not a header/hidden item
      const item = page.locator('ytmusic-responsive-list-item-renderer')
        .filter({ has: page.locator('button[aria-label="Action menu" i]') }).first();
      await item.scrollIntoViewIfNeeded(T);
      await item.hover(T);
      await page.waitForTimeout(300);   // let the overflow (⋮) button fade in on hover
      await item.locator('button[aria-label="Action menu" i]').click({ force: true, ...T });
      await page.locator('ytmusic-menu-popup-renderer').first().waitFor({ state: 'visible', ...T });
    },
  },
  {
    name: 'account-menu',
    path: '/',
    async open(page) {
      // The avatar trigger varies; try several, fall back to the settings button (also a menu).
      const trigger = page.locator('button[aria-label*="Account" i], #avatar-btn, ytmusic-nav-bar img.yt-img-shadow, ytmusic-settings-button').first();
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
  // Add: add-to-playlist dialog, share dialog, settings page, queue, now-playing page...
];
