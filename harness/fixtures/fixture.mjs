// Runtime fixture: intercept youtubei XHR + image requests and serve the deterministic
// fake fixtures built by build-fixtures.mjs. Album art -> black SVG square (kept as a real
// <img>/background so overlay+play-button detection still fires over "media").
import fs from 'fs';
import zlib from 'zlib';

const dataFile = (n) => new URL(`./data/${n}.json`, import.meta.url);
const load = (n) => fs.readFileSync(dataFile(n));
const AVATAR = fs.readFileSync(new URL('./fake-avatar.svg', import.meta.url));
// Non-trivial intrinsic size: a 1x1 collapses YT's intrinsic-sized <img>/yt-img-shadow to
// 0x0, which breaks layout, "visible" checks (avatar trigger) and scrollIntoView (rows).
const BLACK = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256"><rect width="256" height="256" fill="#000"/></svg>');

const browseMap = {
  FEmusic_home: 'browse-home', FEmusic_explore: 'browse-explore',
  FEmusic_moods_and_genres: 'browse-moods', FEmusic_library_landing: 'browse-library',
};

function readBrowseId(req) {
  try {
    const buf = req.postDataBuffer();
    if (!buf) return null;
    let s; try { s = zlib.gunzipSync(buf).toString(); } catch { s = buf.toString('utf8'); }
    return JSON.parse(s).browseId || null;
  } catch { return null; }
}

export async function installFixture(context) {
  // youtubei API -> fake fixtures (unknown endpoints pass through: att/get, log_event, ...)
  await context.route(/youtubei\/v1\//, async (route) => {
    const ep = new URL(route.request().url()).pathname.replace(/^\/youtubei\/v1\//, '');
    let file = null;
    if (ep === 'browse') file = browseMap[readBrowseId(route.request())] || 'browse-home';
    else if (ep === 'search') file = 'search';
    else if (ep === 'music/get_search_suggestions') file = 'search-suggestions';
    else if (ep === 'next') file = 'next';
    else if (ep === 'player') file = 'player';
    else if (ep === 'account/account_menu') file = 'account_menu';
    else if (ep === 'guide') file = 'guide';
    if (!file || !fs.existsSync(dataFile(file))) return route.continue();
    return route.fulfill({ status: 200, contentType: 'application/json', body: load(file) });
  });
  // fake avatar (must beat the black-square net; distinct host path so no conflict)
  await context.route(/fixture\.invalid\/avatar/, (r) => r.fulfill({ contentType: 'image/svg+xml', body: AVATAR }));
  await context.route(/fixture\.invalid\/art/, (r) => r.fulfill({ contentType: 'image/svg+xml', body: BLACK }));
  // safety net: any real thumbnail host -> black square (covers any art we didn't rewrite)
  await context.route(/(yt3|lh3|i)\.(googleusercontent|ytimg|ggpht)\.com|yt3\.ggpht\.com|googleusercontent\.com/, (r) =>
    r.fulfill({ contentType: 'image/svg+xml', body: BLACK }));

  // SSR neutralizer: home/explore/moods/guide ship inline in
  // ytcfg.set({YTMUSIC_INITIAL_DATA: initialData}) on cold load (no XHR to intercept).
  // Empty that array in the document so the SPA has no embedded data and re-fetches every
  // surface via the browse/guide XHR — which the youtubei route above serves as fake.
  // Deterministic, and no fragile in-page hydration hooking. Scoped to the SPA document
  // routes (never youtubei), and only rewrites the main-frame document.
  await context.route(/music\.youtube\.com\/(explore|library|moods_and_genres|search|$|\?)/, async (route) => {
    if (route.request().resourceType() !== 'document') return route.fallback();
    const resp = await route.fetch();
    const html = (await resp.text()).replace("'YTMUSIC_INITIAL_DATA': initialData", "'YTMUSIC_INITIAL_DATA': []");
    return route.fulfill({ response: resp, body: html });
  });
}
