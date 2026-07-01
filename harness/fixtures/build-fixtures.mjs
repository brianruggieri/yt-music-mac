// Build deterministic fake fixtures from raw captures.
// Reads fixtures/capture/*.json ({url,reqBody,status,res}), transforms the `res` body
// into PII-free fake content, writes fixtures/data/<name>.json (the body, ready to serve).
// Also runs a determinism check (transform is idempotent-stable) and a leak spot-check.
import fs from 'fs';
import { transform } from './transform.mjs';

const CAP = 'fixtures/capture';
const OUT = 'fixtures/data';
const fake = JSON.parse(fs.readFileSync('fixtures/fake-user.json', 'utf8'));
fs.mkdirSync(OUT, { recursive: true });

// capture file -> output name
const MAP = {
  'browse-home.json': 'browse-home', 'browse-explore.json': 'browse-explore',
  'browse-moods.json': 'browse-moods', 'browse-library.json': 'browse-library',
  'next.json': 'next', 'player.json': 'player', 'account_menu.json': 'account_menu',
  'guide.json': 'guide', 'search-search.json': 'search',
  'search-music_get_search_suggestions.json': 'search-suggestions',
};

const sampleTitles = (obj) => {
  const out = [];
  (function w(n){ if(out.length>=6) return;
    if(Array.isArray(n)) return n.forEach(w);
    if(n && typeof n==='object'){
      const t = n.musicResponsiveListItemRenderer?.flexColumns?.[0]?.musicResponsiveListItemFlexColumnRenderer?.text?.runs?.[0]?.text
        || n.musicTwoRowItemRenderer?.title?.runs?.[0]?.text;
      if(t) out.push(t);
      for(const k in n) w(n[k]);
    }
  })(obj);
  return out;
};

let ok = 0;
for (const [cap, name] of Object.entries(MAP)) {
  const p = `${CAP}/${cap}`;
  if (!fs.existsSync(p)) { console.log(`SKIP ${cap} (missing)`); continue; }
  const rec = JSON.parse(fs.readFileSync(p, 'utf8'));
  const body = JSON.parse(rec.res);
  // determinism: transform two independent parses, compare
  const a = JSON.stringify(transform(JSON.parse(rec.res), fake));
  const b = JSON.stringify(transform(JSON.parse(rec.res), fake));
  if (a !== b) { console.log(`✗ ${name}: NON-DETERMINISTIC`); continue; }
  const out = transform(body, fake);
  fs.writeFileSync(`${OUT}/${name}.json`, JSON.stringify(out));
  const titles = sampleTitles(out);
  console.log(`✓ ${name}  ${(a.length/1024|0)}KB  sample: ${titles.slice(0,4).join(' | ') || '(no item renderers)'}`);
  ok++;
}
console.log(`\nBuilt ${ok}/${Object.keys(MAP).length} fixtures → ${OUT}/`);
