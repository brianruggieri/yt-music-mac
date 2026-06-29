# DESIGN.md — YouTube Music for macOS, Light Mode

> Source of truth for the **light theme only**. Dark mode is YouTube Music's own,
> shipped and untouched — the engine no-ops in dark. Everything here governs what
> the runtime light-theme engine produces when macOS is in light appearance.
>
> Implementation lives in [`youtube-music-player/LightThemeEngine.swift`](youtube-music-player/LightThemeEngine.swift);
> verification lives in [`harness/`](harness/). This doc is the *intent*; those are
> the *mechanism* and the *gate*.

## The one thing to remember

**It's still YouTube Music — just in daylight.** A user who flips macOS to light
should feel like the same app turned the lights on, not like a third-party reskin.
The red they know is still the heartbeat; everything else is a calm, legible
off-white. We earn the right to call it "YouTube Music" by keeping the brand red
honest and the contrast unimpeachable.

## Non-negotiable: accessibility is priority #1

Every color decision below is subordinate to contrast. The order of operations is
always **(1) does it meet WCAG, (2) is it on-brand** — never the reverse. If a
brand choice can't clear the bar, the brand choice changes, not the bar.

| Check | Target | Where enforced |
|-------|--------|----------------|
| Text contrast (WCAG 1.4.3) | **4.5:1** normal, **3:1** large (≥24px, or ≥18.66px bold) | Engine runtime `audit()` clamps live; harness `auditContrast()` **fails the build** |
| Non-text / surface (1.4.11) | **3:1** for meaningful UI; card-vs-page boundary ≥**1.35:1** ratio | Engine `auditSurfaces()` adds hairline borders; harness reports |
| Icon contrast (1.4.11) | **3:1** for neutral glyphs in controls | Harness `audit.js` icon pass |
| Focus visible (2.4.7) | Visible ring on every focusable, `:focus-visible` only | Engine `FOCUS` rules |
| Graceful failure | If light coverage stays <85% over 4 audits → revert to native dark | Engine `degraded` path |

If a Google redesign breaks the theme, we **fall back to dark, not to broken light**.
That degradation path is itself an accessibility feature — never ship a half-contrasted UI.

---

## Color system

### Brand palette (locked)

Two reds, because pure YouTube Red is ~4:1 on our light surface: it **passes** the
3:1 bar for icons/large/UI but **fails** the 4.5:1 bar for body text. So red splits
by role.

| Token | Hex | Use | Contrast on `#F3F3F3` |
|-------|-----|-----|------------------------|
| **YouTube Red** | `#FF0033` (`#f03`) | Brand red — the exact value in YT Music's own logo. Icons, the play-button circle, progress fill, equalizer bars, playing dot, selected-nav marker. **Non-text / large only.** | ~4:1 → OK for UI/large (≥3:1), **never body text** |
| **Red Ink** | `#CC0029` | The text-safe red — same `#f03` hue, darkened. Any red *text*, link hover, active-tab underline, thin strokes. | **~5.3:1** → AA for all text |
| White knockout | `#FFFFFF` | The triangle/glyph cut out of a red play button. | ~4:1 on `#FF0033` → OK for the large glyph |

**The rule, stated once:** red text or a thin red line uses **Red Ink `#CC0029`**.
A red shape, fill, icon, or indicator uses **YouTube Red `#FF0033`**. Both share the
logo's `#f03` hue so every red on screen matches the wordmark. There is no third red.
Do not introduce pink/orange tints — the engine preserves hue, so red stays red
automatically; don't fight it.

### Surface palette (derived + pinned)

The engine learns these by inverting YT's own primitives, then pins the criticals
inline (`PIN_TOKENS`) because YT poisons the semantic tokens from page content.

| Role | Hex | Token / pin |
|------|-----|-------------|
| Page background | `#F3F3F3` | `--ytmusic-background`, `--ytmusic-general-background-c`, nav bar |
| Elevated surface (raised rows/cards) | `#E7E7E7` | `--ytmusic-general-background-a/b` |
| Brand background solid | `#DEDEDE` | `--ytmusic-brand-background-solid` |
| Sidebar / guide strip | `#F3F3F3` | `#guide-wrapper` pin |
| Popup / menu surface | `#FAFAFA` | `pinMenu()` |
| Hairline divider | `rgba(0,0,0,0.08)` | `ENHANCE` shelf borders |
| Card boundary (1.4.11) | `rgba(0,0,0,0.12)` | `auditSurfaces()` injected border |

### Text & focus

| Role | Value | Notes |
|------|-------|-------|
| Primary text | ~`#0A0A0A` (near-black) | Inverted from YT's white primitive |
| Secondary / caption | **~7:1** (≈`#525252`) | YT's secondary text is *translucent* white. The cascade fix: `invert()` preserves the alpha for text (`keepAlpha`), so it flips to a dark translucent grey instead of a near-invisible one — fixing it everywhere by cascade, not per-element. The audit is a backstop and clamps any residual to the **READABLE (~7:1)** target, matching YT's own `#555` secondary rather than the bare 4.5 floor. |
| Focus ring | `#1A73E8` (blue) | **Deliberately not red.** See below. |

**Alpha is not optional.** Any contrast check — engine or harness — MUST composite a
translucent foreground over its real background first. A near-transparent black scores
as solid black if you read the raw rgb, which is exactly how invisible text passes an
audit. This rule lives in `audit()`, `harness/lib/audit.js`, and `probe-inpage.js`.

---

## Where red shows up (and where it doesn't)

Red is the brand's pulse — used **on purpose, in few places**, so it keeps meaning.
In light mode it appears in exactly three contexts. Everywhere else stays neutral.

### 1. Active / playing state — "this is live"
- Progress / scrubber **fill** → YouTube Red `#FF0033` (already brand-hued; keep it).
- Playing-track **equalizer bars** and the **now-playing dot** → `#FF0033`.
- Now-playing **track title text** → Red Ink `#CC0029` (it's text → text-safe red).
- Selected sidebar / nav item: a `#FF0033` leading indicator bar or dot (the label
  text stays near-black for legibility; red is the *marker*, not the *word*).

### 2. Play buttons — the brand mark
- **Every** filled play circle (`ytmusic-play-button-renderer`) is a `#FF0033` circle
  with a white triangle — header CTA, sidebar/playlist hover buttons, inline rows.
  It mirrors the logo's play glyph, so red consistently means "play" across the app.
  White-on-red is ~4:1, clears 3:1 for the glyph.
- Transport play/pause in the player bar is a different element
  (`tp-yt-paper-icon-button`) and stays neutral near-black.

### 3. Hover / active accents — red threaded through navigation
- Section **"More"** / "Show all" links → Red Ink `#CC0029`.
- Active **tab underline** → 2px `#CC0029`.
- **Link hover** color → Red Ink `#CC0029`.
- These are all text or thin lines → **Red Ink only.**

### Where red must NOT go
- **Body text, captions, metadata** — neutral, always.
- **Focus rings** — blue (next section).
- **Backgrounds / large fills** of non-active surfaces — a red page is fatigue, not brand.
- **Destructive vs. brand confusion** — if a delete/remove action is ever styled, it
  must be visually distinct from brand red (e.g. an outline, not a red fill), so
  "this is YouTube" never reads as "this is dangerous."
- **Native macOS chrome** — left neutral by choice. `AccentColor.colorset` stays empty
  (system default). Red is a *web-surface* brand cue here, not a window-chrome one.

---

## Focus rings stay blue (`#1A73E8`)

This is the one place we *don't* use brand red, on purpose. In this UI **red already
means "playing / active / selected."** If the keyboard focus ring were also red, a
focused-but-not-playing item would read as playing. Blue gives focus its own
unambiguous meaning: **red = state, blue = "your keyboard is here."** Both clear WCAG
(blue is ~4.5:1 on white as a 2px ring); the win is semantic, not just contrast.
Rings render on `:focus-visible` only, so mouse clicks never draw them.

---

## Depth & shape (light-mode polish)

Light surfaces need help reading as layered (dark mode gets depth for free from
glow; light needs shadow + edges).

- **Thumbnails / cards**: a single tight elevation shadow that hugs the image
  (`0 1px 4px rgba(0,0,0,0.18)`) + 8px radius (`ENHANCE`). Deliberately *not* a wide
  soft halo — the shadow should read as the image lifting slightly, not floating.
- **Shelves / carousels**: `rgba(0,0,0,0.08)` hairline so sections separate.
- **Unselected category chips**: outlined pills (subtle fill + `rgba(0,0,0,0.22)`
  border) so they read as buttons; the **selected** chip keeps YT's filled style, so
  selected vs. unselected stays obvious.
- **Cards that match the page too closely** get a `rgba(0,0,0,0.12)` border injected
  at runtime (1.4.11 surface contrast).

---

## Implementation map

What to touch in `LightThemeEngine.swift` to realize the red placements above. The
palette and accessibility machinery already exist; the red placements are the delta.

| Intent | Engine hook | Status |
|--------|-------------|--------|
| Light palette derivation | `scan()` + `invert()` + `PIN_TOKENS` | ✅ shipped |
| Text AA enforcement | `audit()` + `enforceLightness()` | ✅ shipped |
| Surface borders (1.4.11) | `auditSurfaces()` | ✅ shipped |
| Blue focus rings | `FOCUS` | ✅ shipped |
| Degradation to dark | `degraded` / `lowStreak` | ✅ shipped |
| **Play button → red circle/white glyph** | `SURFACE_FIXES`, scoped to `ytmusic-responsive-header-renderer`/`detail-header` (primary only) | ✅ `#FF0033` circle + white knockout |
| **Selected nav item red marker** | `RED` rule on `ytmusic-guide-entry-renderer[active] tp-yt-paper-item` | ✅ 3px inset `#FF0033` left bar |
| **Now-playing title → Red Ink** | `RED` rule, high-specificity to beat the engine's inverted title rule | ✅ `#CC0029` |
| **Active tab underline / link hover → Red Ink** | `RED` rules (`tp-yt-paper-tab.iron-selected`, content-link `:hover`) | ✅ `#CC0029` |
| Progress fill / equalizer → red | YT's brand hue survives the lightness-only invert | ✅ unchanged (already red) |
| Context-menu icons (1.4.11) | `SURFACE_FIXES` dark-pin on `ytmusic-menu-popup-renderer` svgs | ✅ fixed white-on-`#DEDEDE` (was 1.35:1) |
| Translucent secondary text | alpha-composite in `audit()` + both harness auditors | ✅ artist names ~1:1 → 4.53:1 |
| Logo wordmark in light mode | `pinLogo()` fetches YT's SVG, recolours only the white "Music" → `#0f0f0f`, keeps `#f03` | ✅ readable, self-healing, logo design unchanged |
| Self-scan exclusion (perf) | `scan()` skips `#ytm-light-theme` so the stylesheet can't grow unbounded | ✅ fixed flicker + leak |
| Adaptive audit backoff (perf) | full-DOM audits drop to every 6th tick once 6 clean audits bank; `build()` rebuild re-arms | ✅ ~6× less steady-state cost |

When adding red rules, **add them to `ENHANCE`/`SURFACE_FIXES` as declarative data** —
keep the engine free of per-element logic, the way `OVERRIDES` and `FORCE` already are.
Any red *text* rule uses `#CC0029`; any red *fill/icon* rule uses `#FF0033`. New rules
must keep the audit green (see below) — if a red text rule drops below 4.5:1 it's the
wrong red.

---

## Verification (the gate)

Every change is checked from the outside, in the same engine family users run (WebKit).

```bash
cd harness && nvm use && npm test          # all screens × both themes
npm test -- --project=light                # light only
npm run report                             # screenshots + diffs + contrast logs
```

- **Text contrast failures fail the build** in light mode. A red that fails is a bug.
- Add new red surfaces to `SCREENS` / `INTERACTIONS` in `harness/screens.js` so the
  placements above are actually covered, not just defined.
- Commit baselines in `harness/snapshots/` — they're the canary for a YT redesign
  that breaks the theme.

## Definition of done for any light-mode change

1. `npm test -- --project=light` is green (no text contrast failures).
2. Red appears only in the three sanctioned contexts; nowhere else.
3. Red text/lines use `#CC0029`; red fills/icons use `#FF0033`.
4. Focus rings remain blue and visible on keyboard nav.
5. The screen is in `harness/screens.js` coverage, with a committed baseline.
