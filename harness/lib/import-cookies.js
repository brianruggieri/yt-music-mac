// Convert a cookie export from your REAL (already-logged-in) browser into a
// Playwright storageState (auth.json). This sidesteps Google's "browser may not be
// secure" block — we never automate the login, we just reuse the session you have.
//
// How to get the export:
//   1. In your normal browser, install the "Cookie-Editor" extension.
//   2. Go to https://music.youtube.com (logged in).
//   3. Cookie-Editor → Export → "Export as JSON" → save to harness/cookies.json.
//
// Then:  node lib/import-cookies.js cookies.json   (writes ../auth.json)
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const inPath = process.argv[2];
const outPath = resolve(process.argv[3] || join(here, '..', 'auth.json'));
if (!inPath) {
  console.error('usage: node lib/import-cookies.js <cookie-editor-export.json> [out=../auth.json]');
  process.exit(1);
}

// Two accepted inputs. A Cookie-Editor JSON export is the better one — it carries real
// expiry dates, which the CI canary uses to tell a live session from a dead one. But
// installing an extension isn't always possible (Chrome blocks it in Incognito), so we
// also take the raw `Cookie:` request header, copied from DevTools → Network → any
// music.youtube.com request → Request Headers. That header includes the httpOnly auth
// cookies, which `document.cookie` cannot see — which is why it works at all.
//
// The header carries names and values only, so the rest is reconstructed: everything is
// marked secure (we only ever talk to https) and session-scoped. Session-scoped is the
// real cost — expiry is unknowable from a header, so a session imported this way always
// looks live to the canary's staleness check even after Google kills it.
function parseCookieHeader(text) {
  return text
    .split(/;\s*/)
    .filter(Boolean)
    .map((pair) => {
      const eq = pair.indexOf('=');
      if (eq < 1) return null;
      const name = pair.slice(0, eq).trim();
      const value = pair.slice(eq + 1).trim();
      // `__Host-` cookies are host-locked by spec: no domain attribute, path must be /.
      const hostOnly = name.startsWith('__Host-');
      return {
        name,
        value,
        domain: hostOnly ? 'music.youtube.com' : '.youtube.com',
        path: '/',
        session: true,
        secure: true,
        httpOnly: false,
        sameSite: 'no_restriction',
      };
    })
    .filter(Boolean);
}

const text = readFileSync(inPath, 'utf8').trim();
let arr;
try {
  const raw = JSON.parse(text);
  arr = Array.isArray(raw) ? raw : raw.cookies || [];
} catch {
  arr = parseCookieHeader(text);
  console.log(`  (input isn't JSON — read it as a raw Cookie header: ${arr.length} pairs)`);
}

const sameSite = (s) => {
  s = (s || '').toLowerCase();
  if (s === 'strict') return 'Strict';
  if (s === 'none' || s === 'no_restriction') return 'None';
  return 'Lax';
};

const cookies = arr
  .filter((c) => /youtube|google/.test(c.domain || ''))
  .map((c) => ({
    name: c.name,
    value: c.value,
    domain: c.domain.startsWith('.') ? c.domain : c.domain, // keep leading dot if present
    path: c.path || '/',
    expires: c.session ? -1 : Math.round(c.expirationDate ?? c.expires ?? -1),
    httpOnly: !!c.httpOnly,
    secure: !!c.secure,
    sameSite: sameSite(c.sameSite),
  }));

writeFileSync(outPath, JSON.stringify({ cookies, origins: [] }, null, 2));
const loggedIn = cookies.some((c) => /^SAPISID$|^__Secure-3PSID$/.test(c.name));
console.log(`wrote ${outPath}`);
console.log(`  ${cookies.length} youtube/google cookies`);
console.log(`  logged-in signal (SAPISID/__Secure-3PSID): ${loggedIn}`);
if (!loggedIn) console.warn('  ⚠ no login cookie found — make sure you exported while logged in to music.youtube.com');
