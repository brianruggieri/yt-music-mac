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
  FEmusic_non_music_audio: 'browse-podcasts',
  // Self-channel "Personal mix" auto-mix card (a thumbnail-less musicCardShelfRenderer).
  // Exact match, so it wins over the generic `UC` artist-detail prefix below.
  UCselfMix000000000000000: 'browse-self-mix',
};
// Detail pages: browseId is per-entity, so map by PREFIX (any album/playlist/artist detail
// request gets the corresponding fake detail fixture).
function browseFile(browseId) {
  if (!browseId) return null;
  if (browseMap[browseId]) return browseMap[browseId];
  if (browseId.startsWith('MPREb_')) return 'browse-album';
  if (browseId.startsWith('VL')) return 'browse-playlist';
  if (browseId.startsWith('UC')) return 'browse-artist';
  return null;
}

function readBody(req) {
  try {
    const buf = req.postDataBuffer();
    if (!buf) return null;
    let s; try { s = zlib.gunzipSync(buf).toString(); } catch { s = buf.toString('utf8'); }
    return JSON.parse(s);
  } catch { return null; }
}
const readBrowseId = (req) => readBody(req)?.browseId || null;
// Sentinel query -> the "No results" empty-state fixture; any other query -> normal results.
const EMPTY_QUERY = 'zzqxwvkjhgp0987xyz';

// Endpoints YT gates behind an attestation check (see the `att/get` BotGuard call fired
// alongside them): under WebKit, Playwright's context.route/page.route NEVER see these
// requests at the network layer (confirmed with a wildcard page.route('**/*') — it simply
// isn't in the intercepted stream), so they fall through to the real music.youtube.com and
// 401 with no session cookie. That's a regression in YT's own gating, not this harness —
// route-based fixturing can't reach it. Patch window.fetch itself (in-page, pre-network) for
// just this one endpoint instead; see installFixture's `page` param below.
const ATTESTED_ENDPOINT = '/youtubei/v1/playlist/get_add_to_playlist';

export async function installFixture(context, page) {
  // youtubei API -> fake fixtures (unknown endpoints pass through: att/get, log_event, ...)
  await context.route(/youtubei\/v1\//, async (route) => {
    const ep = new URL(route.request().url()).pathname.replace(/^\/youtubei\/v1\//, '');
    let file = null;
    if (ep === 'browse') file = browseFile(readBrowseId(route.request())) || 'browse-home';
    else if (ep === 'search') file = (readBody(route.request())?.query === EMPTY_QUERY) ? 'search-empty' : 'search';
    else if (ep === 'music/get_search_suggestions') file = 'search-suggestions';
    else if (ep === 'next') file = 'next';
    else if (ep === 'player') file = 'player';
    else if (ep === 'account/account_menu') file = 'account_menu';
    else if (ep === 'guide') file = 'guide';
    else if (ep === 'playlist/get_add_to_playlist') file = 'add-to-playlist';
    else if (ep === 'share/get_share_panel') file = 'share-panel';
    else if (ep === 'account/get_setting') file = 'settings';
    if (!file || !fs.existsSync(dataFile(file))) return route.continue();
    return route.fulfill({ status: 200, contentType: 'application/json', body: load(file) });
  });
  // per-entity generated assets: fixture.invalid/asset/<path>.png -> fixtures/assets/<path>.png
  // (album/video/playlist/artist covers + avatar). Missing asset -> black square fallback.
  await context.route(/fixture\.invalid\/asset\//, (route) => {
    // URLs are .png (from the transform); assets on disk are downscaled .jpg. Resolve by
    // stem and serve whichever exists with the right content-type. Missing -> black square.
    const stem = new URL(route.request().url()).pathname.replace(/^\/asset\//, '').replace(/\.(png|jpe?g)$/i, '');
    for (const [ext, ct] of [['jpg', 'image/jpeg'], ['png', 'image/png']]) {
      const file = new URL(`./assets/${stem}.${ext}`, import.meta.url);
      try { if (fs.existsSync(file)) return route.fulfill({ contentType: ct, body: fs.readFileSync(file) }); } catch {}
    }
    return route.fulfill({ contentType: 'image/svg+xml', body: BLACK });
  });
  await context.route(/fixture\.invalid\/art/, (r) => r.fulfill({ contentType: 'image/svg+xml', body: BLACK }));
  // safety net: any real thumbnail host -> black square (covers any art we didn't rewrite)
  await context.route(/(yt3|lh3|i)\.(googleusercontent|ytimg|ggpht)\.com|yt3\.ggpht\.com|googleusercontent\.com/, (r) =>
    r.fulfill({ contentType: 'image/svg+xml', body: BLACK }));
  // hermeticity: never let media playback escape to the real CDN during fixture runs
  // (the transform drops streamingData, but YT's player may still probe googlevideo).
  await context.route(/googlevideo\.com/, (r) => r.abort());

  // SSR neutralizer: home/explore/moods/guide ship inline in
  // ytcfg.set({YTMUSIC_INITIAL_DATA: initialData}) on cold load (no XHR to intercept).
  // Empty that array in the document so the SPA has no embedded data and re-fetches every
  // surface via the browse/guide XHR — which the youtubei route above serves as fake.
  // Deterministic, and no fragile in-page hydration hooking. Scoped to the SPA document
  // routes (never youtubei), and only rewrites the main-frame document.
  await context.route(/music\.youtube\.com\/(explore|library|moods_and_genres|search|settings|podcasts|watch|browse\/|playlist\?|channel\/|$|\?)/, async (route) => {
    if (route.request().resourceType() !== 'document') return route.fallback();
    const resp = await route.fetch();
    const html = (await resp.text())
      .replace("'YTMUSIC_INITIAL_DATA': initialData", "'YTMUSIC_INITIAL_DATA': []")
      // Fake the logged-in flag so the chrome renders the avatar/account UI even with NO real
      // session (CI runs auth-free). Everything behind it — account_menu, guide, the avatar
      // image — is already served fake by the routes above, so the identity is Alex Rivera.
      .replace('"LOGGED_IN":false', '"LOGGED_IN":true');
    return route.fulfill({ response: resp, body: html });
  });

  // Fetch-level fallback for the attested endpoint (see ATTESTED_ENDPOINT comment above):
  // route.mjs can't reach it, so patch window.fetch in-page instead, before any app script
  // runs. Only opted into when a `page` is passed (currently just the add-to-playlist test).
  if (page) {
    const body = load('add-to-playlist').toString('utf8');
    await page.addInitScript(([endpoint, json]) => {
      const orig = window.fetch;
      window.fetch = function (input, init) {
        const url = typeof input === 'string' ? input : input?.url || '';
        if (url.includes(endpoint)) {
          return Promise.resolve(new Response(json, { status: 200, headers: { 'content-type': 'application/json' } }));
        }
        return orig.apply(this, arguments);
      };
    }, [ATTESTED_ENDPOINT, body]);
  }
}
