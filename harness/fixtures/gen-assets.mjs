// Generate all fake-media assets via codex-imagegen (real AI, codex login, no API key).
// Reads assets-manifest.json, builds a per-type prompt, runs generations with a small
// concurrency pool. Skips assets that already exist (resumable). One-time; outputs committed.
import fs from 'fs';
import { execFile, execFileSync } from 'child_process';
import path from 'path';

const BIN = process.env.HOME + '/.local/bin/codex-imagegen';
const manifest = JSON.parse(fs.readFileSync('fixtures/assets-manifest.json', 'utf8'));
const CONCURRENCY = 4;

const prompt = (a) => {
  switch (a.type) {
    case 'album':
      return `Professional album cover art for the album "${a.title}" by the musician "${a.artist}". Evocative, artistic composition whose mood matches the album title. No text, no lettering, no words. Square album artwork, high detail.`;
    case 'video':
      return `Cinematic music-video thumbnail / film still for the song "${a.title}" by "${a.artist}". Atmospheric, moody, cinematic lighting, landscape composition. No text, no lettering, no captions.`;
    case 'playlist':
      return `Cover art for a music playlist titled "${a.title}". Artistic mood-board imagery matching the title's vibe. No text, no lettering. Square.`;
    case 'artist':
      return `Moody editorial promotional portrait of a musician named "${a.name}". Stylish studio lighting, centered subject, shallow depth of field. No text, no lettering. Square.`;
    case 'avatar':
      return `Friendly professional headshot portrait photo of a person named ${a.name}, warm neutral studio background, centered face and shoulders, natural lighting, no text. Square.`;
    default: return `Abstract artistic square image. No text.`;
  }
};
const sizeOf = (a) => (a.type === 'video' ? '1536x1024' : '1024x1024');

// Final committed asset is a downscaled .jpg (photographic, ~50KB vs ~2MB PNG). Generate a
// full-res PNG, then convert to .jpg and drop the PNG. Skip assets whose .jpg already exists.
const dim = (a) => (a.type === 'video' ? '640x360' : '512x512');
const jobs = manifest.map((a) => ({ a, png: `fixtures/assets/${a.id}.png`, jpg: `fixtures/assets/${a.id}.jpg` }))
  .filter((j) => !fs.existsSync(j.jpg));
console.log(`${manifest.length} assets, ${jobs.length} to generate (${manifest.length - jobs.length} already present)`);
for (const j of jobs) fs.mkdirSync(path.dirname(j.jpg), { recursive: true });

let done = 0, failed = [];
const run = (j) => new Promise((resolve) => {
  execFile(BIN, ['generate', '--prompt', prompt(j.a), '--out', j.png, '--size', sizeOf(j.a), '--quality', 'high'],
    { timeout: 240000 }, (err) => {
      if (err || !fs.existsSync(j.png)) { failed.push(j.a.id); console.log(`✗ ${j.a.id}: ${err ? err.message.split('\n')[0] : 'no file'}`); return resolve(); }
      try {
        execFileSync('magick', [j.png, '-resize', dim(j.a) + '^', '-gravity', 'center', '-extent', dim(j.a), '-quality', '86', j.jpg]);
        fs.unlinkSync(j.png);
        console.log(`✓ ${++done}/${jobs.length} ${j.a.id}`);
      } catch (e) { failed.push(j.a.id); console.log(`✗ ${j.a.id}: convert ${e.message.split('\n')[0]}`); }
      resolve();
    });
});

// simple concurrency pool
const queue = [...jobs];
async function worker() { while (queue.length) await run(queue.shift()); }
await Promise.all(Array.from({ length: CONCURRENCY }, worker));
console.log(`\nDONE. generated ${done}, failed ${failed.length}${failed.length ? ': ' + failed.join(', ') : ''}`);
