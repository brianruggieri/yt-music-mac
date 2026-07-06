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
  // Text objects carry their own precomputed a11y label with the ORIGINAL text (a rewritten
  // subtitle still announced "Paramore • 18M views" / "Profile • @realhandle" — the security
  // review's main leak). Rewriting only runs[] leaves that label; keep it in lockstep.
  if (textObj && textObj.accessibility && textObj.accessibility.accessibilityData
      && typeof textObj.accessibility.accessibilityData.label === 'string') {
    textObj.accessibility.accessibilityData.label = str;
  }
}

// Deterministic dealer: rolling index over a pool, stable across a fixed traversal.
function dealer(pool) { let i = 0; return () => pool[i++ % pool.length]; }

export function transform(root, fake) {
  const nextSong = dealer(fake.songs);
  const nextAlbum = dealer(fake.albums);
  const nextArtist = dealer(fake.artists);
  const nextPlaylist = dealer(fake.playlists);
  const np = fake.nowPlaying;

  // original -> fake name pairs collected while rewriting visible runs. A final pass
  // rewrites accessibility `label`s that embed the ORIGINAL names ("Play <title> - <artist>")
  // — the runs got faked but aria labels are separate strings, and leaving them leaks the
  // real content names into the DOM. Only labels are touched, so structural ones the test
  // openers rely on ("Action menu") survive.
  const renames = new Map();
  function rename(orig, fk) {
    if (typeof orig === 'string' && orig.length > 2 && orig !== fk) renames.set(orig, fk);
  }
  function firstRun(textObj) {
    return (textObj && Array.isArray(textObj.runs) && textObj.runs[0] && textObj.runs[0].text) || null;
  }

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
    // feedbackTokens are session-bound action blobs from the real logged-in capture. Not
    // replayable without the account's cookies, but a mock harness has no use for ~2k real
    // ones — blank them (security review hygiene).
    if (typeof node.feedbackToken === 'string') node.feedbackToken = '';
    // The real typed search query rides in every result's searchEndpoint (filter chips,
    // suggestions) — swap it for a fake in-universe query.
    if (node.searchEndpoint && typeof node.searchEndpoint.query === 'string') node.searchEndpoint.query = 'nova sonder';
    // player.json: streamingData holds signed googlevideo playback URLs that embed the
    // CAPTURING CLIENT'S REAL PUBLIC IP (ip=..., percent-encoded inside signatureCipher —
    // invisible to the host sweep) plus signatures; playbackTracking holds real session
    // params (ei/plid/docid/referrer). Playback can't work against fixtures anyway (the
    // signed URLs are IP-bound and expired) — drop both subtrees. [security review, Medium]
    if (node.streamingData) delete node.streamingData;
    if (node.playbackTracking) delete node.playbackTracking;

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
      // record originals (title + every artist run) for the aria-label scrub
      if (col(0)) rename(firstRun(col(0).text), s.title);
      if (col(1) && col(1).text && Array.isArray(col(1).text.runs)) {
        for (const run of col(1).text.runs) if (!isSep(run.text)) rename(run.text, s.artist);
      }
      if (col(0)) setText(col(0).text, s.title);
      if (col(1)) setText(col(1).text, `${s.artist} • ${s.views}`);
      if (col(2)) { rename(firstRun(col(2).text), s.album); setText(col(2).text, s.album); }
      // trailing duration column, when present
      const fx = r.fixedColumns && r.fixedColumns[0] && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer;
      if (fx) setText(fx.text, s.durationText);
      setThumb(r, `${ASSET}/album/${slug(s.album)}.png`);   // a track row shows its album art
    }
    if (node.musicTwoRowItemRenderer) {
      const r = node.musicTwoRowItemRenderer;
      const orig = firstRun(r.title);
      const sub0 = r.subtitle && r.subtitle.runs && r.subtitle.runs[0] && r.subtitle.runs[0].text || '';
      // aspectRatio is the reliable card-type signal: 16:9 = video, SQUARE = album/playlist/artist.
      const is169 = /16_9/.test(r.aspectRatio || '');
      let fakeTitle;
      if (is169) { const s = nextSong(); fakeTitle = s.title; setText(r.title, s.title); setText(r.subtitle, `${s.artist} • ${s.views}`); setThumb(r, `${ASSET}/video/${slug(s.title)}.png`); }
      else if (/playlist/i.test(sub0)) { const p = nextPlaylist(); fakeTitle = p; setText(r.title, p); setText(r.subtitle, `Playlist • ${fake.profile.name}`); setThumb(r, `${ASSET}/playlist/${slug(p)}.png`); }
      else if (/artist|subscriber/i.test(sub0)) { const a = nextArtist(); fakeTitle = a; setText(r.title, a); setText(r.subtitle, 'Artist'); setThumb(r, `${ASSET}/artist/${slug(a)}.png`); }
      else { const a = nextAlbum(); fakeTitle = a.title; setText(r.title, a.title); setText(r.subtitle, a.subtitle); setThumb(r, `${ASSET}/album/${slug(a.title)}.png`); }
      rename(orig, fakeTitle);
      // Card aria labels can embed the whole EPISODE DESCRIPTION (news/podcast cards) — real
      // third-party content the rename pass can't know. Overwrite content labels in this card
      // (contains the original title, or long = descriptive); short structural labels
      // ("Action menu") survive.
      (function fixL(n) {
        if (!n || typeof n !== 'object') return;
        for (const k in n) {
          if (k === 'label' && typeof n[k] === 'string') {
            if ((orig && n[k].includes(orig)) || n[k].length > 60) n[k] = fakeTitle;
          } else fixL(n[k]);
        }
      })(r);
    }
    // Podcast/news EPISODE cards (explore): title + subtitle + a full episode DESCRIPTION,
    // all real third-party content, echoed again into play/pause aria labels.
    if (node.musicMultiRowListItemRenderer) {
      const r = node.musicMultiRowListItemRenderer, s = nextSong();
      const orig = firstRun(r.title);
      rename(orig, s.title);
      rename(firstRun(r.secondTitle), `${s.artist} Radio Hour`);   // show name — real podcast titles leaked here
      setText(r.title, s.title);
      setText(r.secondTitle, `${s.artist} Radio Hour`);
      setText(r.subtitle, `${s.artist} • Episode`);
      setText(r.description, 'A weekly session of new discoveries, deep cuts, and conversation from the studio.');
      setThumb(r, `${ASSET}/video/${slug(s.title)}.png`);
      (function fixL(n) {
        if (!n || typeof n !== 'object') return;
        for (const k in n) {
          if (k === 'label' && typeof n[k] === 'string') {
            if ((orig && n[k].includes(orig)) || n[k].length > 60) n[k] = s.title;
          } else fixL(n[k]);
        }
      })(r);
    }
    if (node.playlistPanelVideoRenderer) {
      const r = node.playlistPanelVideoRenderer, s = nextSong();
      rename(firstRun(r.title), s.title);
      if (r.longBylineText && Array.isArray(r.longBylineText.runs)) {
        for (const run of r.longBylineText.runs) if (!isSep(run.text)) rename(run.text, s.artist);
      }
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
    // Per-item play/pause a11y labels embed the FULL real title ("Play VIDEO OF …"). The
    // rename map can miss these (escaping/truncation differences), so genericize wholesale —
    // they're per-item play buttons; nothing in the tests or openers keys on them.
    if (node.accessibilityPlayData && node.accessibilityPlayData.accessibilityData) node.accessibilityPlayData.accessibilityData.label = 'Play';
    if (node.accessibilityPauseData && node.accessibilityPauseData.accessibilityData) node.accessibilityPauseData.accessibilityData.label = 'Pause';
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
    // --- detail-page headers ---
    // Album + playlist detail pages: musicResponsiveHeaderRenderer (title, subtitle,
    // strapline = artist/owner line, secondSubtitle = "N songs • length", big art).
    // Branch playlist-vs-album off the subtitle text, same signal as the two-row cards.
    if (node.musicResponsiveHeaderRenderer) {
      const h = node.musicResponsiveHeaderRenderer;
      const subText = (h.subtitle && h.subtitle.runs || []).map((r) => r.text).join('');
      if (/playlist/i.test(subText)) {
        const p = nextPlaylist();
        rename(firstRun(h.title), p);
        rename(firstRun(h.straplineTextOne), fake.profile.name);
        setText(h.title, p);
        setText(h.straplineTextOne, fake.profile.name);
        setThumb(h.thumbnail, `${ASSET}/playlist/${slug(p)}.png`);
        if (h.straplineThumbnail) setThumb(h.straplineThumbnail, `${ASSET}/avatar.png`);
      } else {
        const a = nextAlbum();
        rename(firstRun(h.title), a.title);
        rename(firstRun(h.straplineTextOne), a.artist);
        setText(h.title, a.title);
        setText(h.straplineTextOne, a.artist);
        setThumb(h.thumbnail, `${ASSET}/album/${slug(a.title)}.png`);
        if (h.straplineThumbnail) setThumb(h.straplineThumbnail, `${ASSET}/artist/${slug(a.artist)}.png`);
      }
      if (h.secondSubtitle) setText(h.secondSubtitle, '12 songs • 42 minutes');
      if (h.description) setText(h.description, 'A hand-picked collection for late nights and long drives.');
    }
    // Artist detail page: musicImmersiveHeaderRenderer (name, bio, listener count, hero photo).
    // The captured description is the REAL artist's public bio — must be replaced.
    if (node.musicImmersiveHeaderRenderer) {
      const h = node.musicImmersiveHeaderRenderer, a = nextArtist();
      rename(firstRun(h.title), a);
      setText(h.title, a);
      setText(h.description, `${a} is an independent recording artist. Blending analog warmth with modern production, their releases have quietly built a devoted following.`);
      if (h.monthlyListenerCount) setText(h.monthlyListenerCount, '2.1M monthly listeners');
      setThumb(h.thumbnail, `${ASSET}/artist/${slug(a)}.png`);
    }
    // Search top-result card (musicCardShelfRenderer): title is the real entity name.
    if (node.musicCardShelfRenderer) {
      const c = node.musicCardShelfRenderer, a = nextArtist();
      rename(firstRun(c.title), a);
      setText(c.title, a);
      setText(c.subtitle, 'Artist • 2.1M subscribers');
      setThumb(c.thumbnail, `${ASSET}/artist/${slug(a)}.png`);
    }
    // musicDescriptionShelfRenderer serves TWO surfaces: the artist About bio, and the
    // player LYRICS tab (real copyrighted lyrics + a "Source: Musixmatch" footer). Detect
    // lyrics by the footer/newlines and replace with invented lyrics; else the artist bio.
    if (node.musicDescriptionShelfRenderer) {
      const d = node.musicDescriptionShelfRenderer;
      const footer = (d.footer && d.footer.runs || []).map((r) => r.text).join('');
      const desc = (d.description && d.description.runs || []).map((r) => r.text).join('');
      if (/source:/i.test(footer) || (desc.match(/\n/g) || []).length >= 3) {
        setText(d.description, [
          'City lights bleed into the tide',
          'I keep your signal on my side',
          'Neon hums a quiet tune',
          'Coastline glowing under the moon',
          '',
          'Hold the line, hold the line',
          'Every echo answers back in time',
        ].join('\n'));
        if (d.footer) setText(d.footer, 'Source: fixture');
      } else {
        setText(d.description, 'An independent recording artist blending analog warmth with modern production. Their releases have quietly built a devoted following across late-night radio and festival stages alike.');
        if (d.header) setText(d.header, 'About');
      }
    }
    // Plain-STRING description fields (SEO/share text variants — not runs): real content
    // sentences about the real entity; replace wholesale rather than name-patching.
    if (typeof node.description === 'string' && node.description.length > 20) {
      node.description = 'A hand-picked collection for late nights and long drives.';
    }
    // Add-to-playlist dialog options: each row is one of the user's REAL playlists.
    if (node.playlistAddToOptionRenderer) {
      const r = node.playlistAddToOptionRenderer, p = nextPlaylist();
      rename(firstRun(r.title), p);
      setText(r.title, p);
      if (r.shortBylineText) setText(r.shortBylineText, fake.profile.name);
      setThumb(r, `${ASSET}/playlist/${slug(p)}.png`);   // each row shows its playlist cover
    }
    // Share panel: the copy-link URL carries a per-share `si=` tracking token tied to the
    // account — strip it (keep the plain watch URL; videoIds stay, same policy as elsewhere).
    if (node.copyLinkRenderer && typeof node.copyLinkRenderer.shortUrl === 'string') {
      node.copyLinkRenderer.shortUrl = node.copyLinkRenderer.shortUrl.replace(/[?&]si=[^&]+/, '');
    }
    // --- search suggestions / history (would leak real search history) ---
    if (node.searchSuggestionRenderer) setText(node.searchSuggestionRenderer.suggestion, nextArtist());
    if (node.historySuggestionRenderer) setText(node.historySuggestionRenderer.suggestion, nextArtist());
    // --- sidebar playlists (guide): only user playlists (no icon), never the Home/Explore/Library tabs ---
    if (node.guideEntryRenderer && !node.guideEntryRenderer.icon) {
      const g = node.guideEntryRenderer, p = nextPlaylist();
      rename(firstRun(g.formattedTitle), p);   // aria label carries the real playlist name too
      setText(g.formattedTitle, p);
      if (g.formattedSubtitle) setText(g.formattedSubtitle, fake.profile.name);
    }
    // Third-party share targets (Facebook/X/Pinterest buttons): their hrefs embed the
    // percent-ENCODED real title + an i.ytimg media URL — invisible but real content the
    // rename pass can't match. The links aren't exercised by tests; point them at the sentinel.
    if (node.shareTargetRenderer) {
      (function fixU(n) {
        if (!n || typeof n !== 'object') return;
        for (const k of Object.keys(n)) {
          if (k === 'url' && typeof n[k] === 'string') n[k] = 'https://fixture.invalid/share';
          else fixU(n[k]);
        }
      })(node.shareTargetRenderer);
    }
    // Channel vanity URL ("/@RealHandle") rides in browseEndpoints (account menu et al).
    if (typeof node.canonicalBaseUrl === 'string') node.canonicalBaseUrl = `/${fake.profile.handle}`;
    // Newer ViewModel owner attribution (playlist header): {avatarStackViewModel: {text:
    // {content: "Real Name"}}}, with the same name echoed into accessibilityContext labels.
    if (node.avatarStackViewModel) {
      const av = node.avatarStackViewModel;
      if (av.text && typeof av.text.content === 'string') av.text.content = fake.profile.name;
      (function fixL(n) {
        if (!n || typeof n !== 'object') return;
        for (const k in n) {
          if (k === 'label' && typeof n[k] === 'string') n[k] = fake.profile.name;
          else fixL(n[k]);
        }
      })(av);
    }

    // --- generic thumbnail scrub: any REAL (un-rewritten) thumbnail -> black square. Skip
    // ones a handler already pointed at a fixture asset (fixture.invalid/...), so per-entity
    // art survives. This catches art in renderers we don't special-case (real hosts leak PII). ---
    if (node.musicThumbnailRenderer && node.musicThumbnailRenderer.thumbnail) {
      const th = node.musicThumbnailRenderer.thumbnail;
      if (Array.isArray(th.thumbnails) && th.thumbnails.some(t => t && t.url && !/fixture\.invalid/.test(t.url))) rewriteThumbs(th, ART_SENTINEL);
    }
    if (Array.isArray(node.thumbnails) && node.thumbnails.some(t => t && t.url && !/fixture\.invalid/.test(t.url))) rewriteThumbs(node, ART_SENTINEL);
    // Newer ViewModel shape (avatarViewModel etc.) carries image.sources[].url instead of
    // thumbnails[] — same scrub: owner avatars -> the fake avatar, any other stray -> black.
    if (node.avatarViewModel && node.avatarViewModel.image) {
      for (const s of node.avatarViewModel.image.sources || []) if (s && typeof s.url === 'string') s.url = `${ASSET}/avatar.png`;
    }
    if (Array.isArray(node.sources) && node.sources.some(s => s && typeof s.url === 'string' && /^https?:\/\//.test(s.url) && !/fixture\.invalid/.test(s.url))) {
      for (const s of node.sources) if (s && typeof s.url === 'string') s.url = ART_SENTINEL;
    }

    for (const k in node) visit(node[k]);
  }

  visit(root);

  // Final pass: rewrite ANY remaining string that embeds an original content name — aria
  // labels ("Play Veridis Quo - Daft Punk"), shelf titles ("Playlists by Daft Punk"), share
  // text, etc. Longest originals first so a longer name containing a shorter one
  // ("X Essentials" vs "X") is replaced whole, not partially. Opaque tokens
  // (trackingParams/base64) can't contain the names, so a blanket string pass is safe;
  // structural labels ("Action menu") contain no content names and survive untouched.
  // Compile a word-BOUNDARY matcher per pair: a short real name ("River") must not corrupt a
  // fake value that merely contains it ("Alex Rivera" -> "Alex Afterglowa"). Match only when
  // the original is bounded by non-letter/digit (or string edges), across unicode. Longest
  // first so a longer name containing a shorter one is replaced whole.
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pairs = [...renames.entries()]
    .sort((a, b) => b[0].length - a[0].length)
    .map(([o, f]) => [new RegExp(`(?<![\\p{L}\\p{N}])${esc(o)}(?![\\p{L}\\p{N}])`, 'gu'), f]);
  // Blanket account-identity scrub, applied alongside the renames: any string embedding an
  // email address (e.g. the settings sign-out confirm "Name (user@gmail.com)") becomes the
  // fake identity — content-independent, so it works even where no rename was recorded.
  const EMAIL_LINE = /\S+@\S+\.\S+/;
  // Channel handles ("@realhandle") are account-identifying and can appear in strings no
  // rename covered (profile cards, about lines) — blanket-swap the handle shape. Ordered
  // BEFORE the email check so "user@host.tld" (which also contains @) is judged as email.
  const HANDLE = /(^|[\s(•·])@[A-Za-z0-9._-]{3,30}\b/gu;
  const fixStr = (s) => {
    // plain replace only: a shared /g/ regex's .test() guard would advance lastIndex across
    // strings (the footgun the review flagged); replace() resets it and no-ops on no match.
    for (const [re, f] of pairs) s = s.replace(re, f);
    if (EMAIL_LINE.test(s)) s = `${fake.profile.name} (${fake.profile.email})`;   // no /g/: stateless
    else s = s.replace(HANDLE, `$1${fake.profile.handle}`);   // unconditional: replace() self-resets lastIndex
    return s;
  };
  (function scrub(n) {
    if (Array.isArray(n)) {
      for (let i = 0; i < n.length; i++) {
        if (typeof n[i] === 'string') n[i] = fixStr(n[i]);
        else scrub(n[i]);
      }
      return;
    }
    if (!n || typeof n !== 'object') return;
    for (const k in n) {
      if (typeof n[k] === 'string') n[k] = fixStr(n[k]);
      else scrub(n[k]);
    }
  })(root);

  return root;
}
