import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));

// Single source of truth: extract the light-theme engine JS straight out of the
// Swift file the app ships, so the harness always tests the exact code users run.
// The script lives in a Swift raw string literal: `static let script = #"""<JS>"""#`.
export function loadEngineScript() {
  const swiftPath = join(here, '..', '..', 'youtube-music-player', 'LightThemeEngine.swift');
  const swift = readFileSync(swiftPath, 'utf8');
  const open = swift.indexOf('#"""');
  const close = swift.lastIndexOf('"""#');
  if (open < 0 || close < 0 || close <= open) {
    throw new Error('Could not find the engine script delimiters in LightThemeEngine.swift');
  }
  return swift.slice(open + 4, close);
}
