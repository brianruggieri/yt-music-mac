// Deterministic transform walker: rewrites captured youtubei responses into fake,
// PII-free, reproducible content. Frozen structure (from capture) + faked text +
// black-square art sentinels = deterministic screenshots. Pure function, no I/O.

export const ART_SENTINEL = 'https://fixture.invalid/art.png';
export const AVATAR_SENTINEL = 'https://fixture.invalid/avatar.svg';

const isSep = (t) => !t || /^[\s•&,·|/-]+$/.test(t);

// One text object ({runs:[{text,...}]}) -> single run with `str` (drops nav endpoints;
// fine for screenshots). Preserves the object identity so siblings stay intact.
function setText(textObj, str) {
  if (textObj && Array.isArray(textObj.runs)) textObj.runs = [{ text: str }];
}

// Deterministic dealer: rolling index over a pool, stable across a fixed traversal.
function dealer(pool) { let i = 0; return () => pool[i++ % pool.length]; }

export function transform(root, fake) {
  const nextSong = dealer(fake.songs);
  const nextAlbum = dealer(fake.albums);
  const nextArtist = dealer(fake.artists);
  const nextPlaylist = dealer(fake.playlists);
  const np = fake.nowPlaying;

  function rewriteThumbs(node, sentinel) {
    if (node && Array.isArray(node.thumbnails)) {
      for (const t of node.thumbnails) if (t && typeof t.url === 'string') t.url = sentinel;
    }
  }

  // Per-entity generated assets (album/video/playlist/artist/avatar) served by the fixture
  // route from fixtures/assets/<path>.png. slug() must match the manifest ids.
  const ASSET = 'https://fixture.invalid/asset';
  const slug = (s) => String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  // point every thumbnail inside a renderer subtree at one asset url
  function setThumb(node, url) {
    (function f(n) {
      if (!n || typeof n !== 'object') return;
      if (Array.isArray(n.thumbnails)) for (const t of n.thumbnails) if (t && typeof t.url === 'string') t.url = url;
      for (const k in n) f(n[k]);
    })(node);
  }

  function visit(node) {
    if (Array.isArray(node)) { for (const x of node) visit(x); return; }
    if (!node || typeof node !== 'object') return;

    // scrub the pseudonymous session id that rides in responseContext (committed fixtures
    // shouldn't carry it); leave opaque trackingParams alone (load-bearing, non-personal).
    if (typeof node.visitorData === 'string') node.visitorData = '';

    // Strip lazy-load continuations: otherwise the SPA fires continuation XHRs (served the
    // same home again) and how many fire is timing-dependent -> variable layout -> flaky
    // screenshots. Removing them freezes each surface to exactly its first page.
    for (const k of Object.keys(node)) {
      if (k === 'continuations' || k === 'continuationEndpoint' || k === 'continuationItemRenderer' || k === 'nextContinuationData') delete node[k];
    }

    // --- content renderers ---
    if (node.musicResponsiveListItemRenderer) {
      const r = node.musicResponsiveListItemRenderer, s = nextSong();
      const fc = r.flexColumns || [];
      const col = (i) => fc[i] && fc[i].musicResponsiveListItemFlexColumnRenderer;
      if (col(0)) setText(col(0).text, s.title);
      if (col(1)) setText(col(1).text, `${s.artist} • ${s.views}`);
      if (col(2)) setText(col(2).text, s.album);
      // trailing duration column, when present
      const fx = r.fixedColumns && r.fixedColumns[0] && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer;
      if (fx) setText(fx.text, s.durationText);
      setThumb(r, `${ASSET}/album/${slug(s.album)}.png`);   // a track row shows its album art
    }
    if (node.musicTwoRowItemRenderer) {
      const r = node.musicTwoRowItemRenderer;
      const sub0 = r.subtitle && r.subtitle.runs && r.subtitle.runs[0] && r.subtitle.runs[0].text || '';
      // aspectRatio is the reliable card-type signal: 16:9 = video, SQUARE = album/playlist/artist.
      const is169 = /16_9/.test(r.aspectRatio || '');
      if (is169) { const s = nextSong(); setText(r.title, s.title); setText(r.subtitle, `${s.artist} • ${s.views}`); setThumb(r, `${ASSET}/video/${slug(s.title)}.png`); }
      else if (/playlist/i.test(sub0)) { const p = nextPlaylist(); setText(r.title, p); setText(r.subtitle, `Playlist • ${fake.profile.name}`); setThumb(r, `${ASSET}/playlist/${slug(p)}.png`); }
      else if (/artist|subscriber/i.test(sub0)) { const a = nextArtist(); setText(r.title, a); setText(r.subtitle, 'Artist'); setThumb(r, `${ASSET}/artist/${slug(a)}.png`); }
      else { const a = nextAlbum(); setText(r.title, a.title); setText(r.subtitle, a.subtitle); setThumb(r, `${ASSET}/album/${slug(a.title)}.png`); }
    }
    if (node.playlistPanelVideoRenderer) {
      const r = node.playlistPanelVideoRenderer, s = nextSong();
      setText(r.title, s.title);
      setText(r.longBylineText, `${s.artist} • ${s.album} • 2024`);
      setText(r.lengthText, s.durationText);
      setThumb(r, `${ASSET}/album/${slug(s.album)}.png`);
    }
    // --- now-playing (player.json) ---
    if (node.videoDetails && typeof node.videoDetails === 'object') {
      const v = node.videoDetails;
      if ('title' in v) v.title = np.title;
      if ('author' in v) v.author = np.artist;
      if ('lengthSeconds' in v) v.lengthSeconds = String(np.durationSeconds);
      rewriteThumbs(v.thumbnail, `${ASSET}/album/${slug(np.album)}.png`);   // now-playing art
    }
    // storyboard scrubber sprite (non-visual seek preview) carries a real videoId URL — blank it
    if (node.playerStoryboardSpecRenderer) node.playerStoryboardSpecRenderer.spec = '';
    if (node.microformatDataRenderer) {
      const m = node.microformatDataRenderer;
      if ('title' in m) m.title = `${np.title} - ${np.artist}`;
      if (m.pageOwnerDetails && 'name' in m.pageOwnerDetails) m.pageOwnerDetails.name = np.artist;
    }
    // --- identity (account_menu) ---
    if (node.activeAccountHeaderRenderer) {
      const h = node.activeAccountHeaderRenderer;
      setText(h.accountName, fake.profile.name);
      setText(h.channelHandle, fake.profile.handle);
      rewriteThumbs(h.accountPhoto, `${ASSET}/avatar.png`);
    }
    // shelf strapline = the personalized owner name ("BRIAN RUGGIERI") above a shelf title;
    // it's the real account name, so swap it for the fake user (keep the shelf title itself).
    // Also scrub any accessibility label in this header that embeds that name (aria leaks PII).
    if (node.musicCarouselShelfBasicHeaderRenderer && node.musicCarouselShelfBasicHeaderRenderer.strapline) {
      const H = node.musicCarouselShelfBasicHeaderRenderer;
      const orig = H.strapline.runs && H.strapline.runs[0] && H.strapline.runs[0].text;
      setText(H.strapline, fake.profile.name);
      setThumb(H, `${ASSET}/avatar.png`);   // the round owner avatar beside the strapline
      if (orig) (function fix(n) {
        if (!n || typeof n !== 'object') return;
        if (typeof n.label === 'string' && n.label.includes(orig)) n.label = n.label.split(orig).join(fake.profile.name);
        for (const k in n) fix(n[k]);
      })(H);
    }
    // --- search suggestions / history (would leak real search history) ---
    if (node.searchSuggestionRenderer) setText(node.searchSuggestionRenderer.suggestion, nextArtist());
    if (node.historySuggestionRenderer) setText(node.historySuggestionRenderer.suggestion, nextArtist());
    // --- sidebar playlists (guide): only user playlists (no icon), never the Home/Explore/Library tabs ---
    if (node.guideEntryRenderer && !node.guideEntryRenderer.icon) {
      setText(node.guideEntryRenderer.formattedTitle, nextPlaylist());
      if (node.guideEntryRenderer.formattedSubtitle) setText(node.guideEntryRenderer.formattedSubtitle, fake.profile.name);
    }

    // --- generic thumbnail scrub: any REAL (un-rewritten) thumbnail -> black square. Skip
    // ones a handler already pointed at a fixture asset (fixture.invalid/...), so per-entity
    // art survives. This catches art in renderers we don't special-case (real hosts leak PII). ---
    if (node.musicThumbnailRenderer && node.musicThumbnailRenderer.thumbnail) {
      const th = node.musicThumbnailRenderer.thumbnail;
      if (Array.isArray(th.thumbnails) && th.thumbnails.some(t => t && t.url && !/fixture\.invalid/.test(t.url))) rewriteThumbs(th, ART_SENTINEL);
    }
    if (Array.isArray(node.thumbnails) && node.thumbnails.some(t => t && t.url && !/fixture\.invalid/.test(t.url))) rewriteThumbs(node, ART_SENTINEL);

    for (const k in node) visit(node[k]);
  }

  visit(root);
  return root;
}
