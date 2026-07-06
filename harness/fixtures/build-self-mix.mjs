// One-off builder for browse-self-mix.json: the self-channel "Personal mix" auto-mix card.
// Clones the REAL musicCardShelfRenderer shape out of search.json (valid renderer subtree,
// real trackingParams) and reshapes it into the thumbnail-less header+row variant. Output is
// post-transform (fake, PII-free, deterministic) — matches how transform.mjs would emit it.
import fs from 'fs';
const search = JSON.parse(fs.readFileSync(new URL('./data/search.json', import.meta.url)));

let card = null;
(function f(n){ if(!n||typeof n!=='object'||card)return; if(n.musicCardShelfRenderer){card=n.musicCardShelfRenderer;return;} for(const k in n) f(n[k]); })(search);
card = JSON.parse(JSON.stringify(card));

const setRuns = (obj, str) => { obj.runs = [{ text: str }]; if (obj.accessibility) obj.accessibility.accessibilityData.label = str; };

// Header: big "Personal mix" title + "Private" badge subtitle (renders uppercase). Generic
// YTM section labels, preserved like "Listen again" — not PII.
setRuns(card.title, 'Personal mix');
setRuns(card.subtitle, 'Private');
// Thumbnail-less variant: drop the hero thumbnail so the header sits flush in the card's
// top-left corner (this is what exposes the light-mode box padding bug).
delete card.thumbnail;

// One nested mix row (musicResponsiveListItemRenderer). Fake, deterministic content.
const row = card.contents[0].musicResponsiveListItemRenderer;
const col = (i) => row.flexColumns[i] && row.flexColumns[i].musicResponsiveListItemFlexColumnRenderer;
if (col(0)) setRuns(col(0).text, "Alex Rivera's Mix");
if (col(1)) setRuns(col(1).text, 'Made for sharing. Based on your recent music and always updating.');
if (col(2)) setRuns(col(2).text, '');
// point every thumbnail in the row at the deterministic asset sentinel (black-square route)
(function setThumb(n){ if(!n||typeof n!=='object')return; if(Array.isArray(n.thumbnails)) for(const t of n.thumbnails) if(t&&typeof t.url==='string') t.url='https://fixture.invalid/asset/album/personal-mix.png'; for(const k in n) setThumb(n[k]); })(row);
card.contents = [ card.contents[0] ];

const out = {
  responseContext: { serviceTrackingParams: [], responseId: 'fixture-self-mix' },
  contents: { singleColumnBrowseResultsRenderer: { tabs: [ { tabRenderer: {
    content: { sectionListRenderer: { contents: [ { musicCardShelfRenderer: card } ] } },
    selected: true,
  } } ] } },
  trackingParams: 'fixture',
};
fs.writeFileSync(new URL('./data/browse-self-mix.json', import.meta.url), JSON.stringify(out, null, 1));
console.log('wrote data/browse-self-mix.json', fs.statSync(new URL('./data/browse-self-mix.json', import.meta.url)).size, 'bytes');
