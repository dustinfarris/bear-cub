# Bear Cub — read this before designing

Bear Cub is a family chore kiosk: a fridge-mounted tablet, **1280 × 800 CSS px landscape**, read from across a kitchen by two kids, one of them a pre-reader. The real app is Phoenix LiveView (server-rendered HTML), **not React** — so this design system ships **no components**: `window.BearCub` is empty. Build every piece yourself as plain JSX, styled only with the vocabulary below. Your output is a visual and timing spec that gets hand-ported to HEEx; the closer you stay to these class and token names, the more directly it ports.

## Setup

Link `styles.css` once. No provider, no wrapper. Light theme is the default and the only one the kiosk uses. The page ground is `bg-base-300`; the kiosk is `grid h-dvh grid-cols-2 gap-4 p-4`, one `bg-base-100 rounded-lg` column per kid.

## Styling idiom: Tailwind utilities + CSS tokens

`_ds_bundle.css` is a **compiled** Tailwind v4 build: it contains only the utility classes the app already uses, not all of Tailwind. A class that is not in that file does nothing. Read it before styling; when you need a value it lacks, use an inline `style` with a token — never a new hex.

| Meaning | Tokens / classes |
|---|---|
| Routine = time of day | `var(--routine-morning)` `var(--routine-evening)` (+ `-content`) |
| Pending within a routine | `var(--routine-morning-tint)` `var(--routine-evening-tint)` |
| Outline of a routine (dashed slot, empty segment) | `var(--routine-morning-edge)` `var(--routine-evening-edge)` |
| Earned something (the one reward color) | `bg-success` `text-success-content` `text-success` `ring-success`, `var(--paid-tint)` `var(--paid-edge)` `var(--paid-content)` |
| Penalty / failed | `bg-warning` `text-warning-content` `text-warning`; declined = `text-error` |
| Reward cards: fixed neutral surface; extras' text color | `var(--extra-card-background)` `var(--extra-card-content)` |
| Controls on an extra's surface (stepper discs) | `var(--extra-card-control)` |
| Pending extra (and open count panel) ground / edge | the kid's color at 12% / 45% mixed in oklab into `var(--color-base-100)` |
| Surfaces / text | `bg-base-100` `bg-base-300` `text-base-content/40` `text-base-content/60` |
| Unavailable | `opacity-45` plus a glyph — never a second surface color |

**A kid's color is data, not a token** — pass it inline (`style={{ backgroundColor: kid.color }}`). Use placeholder kids ("Kid A" `#2563eb`, "Kid B" `#db2777`).

**Type.** `font-reward` (Nunito, 700–900) is for celebratory strings only — kid names, point totals, badges, chips, praise, shop titles and prices — at `font-black` or `font-extrabold`, never below `text-sm`. Chore labels, times and anything a parent scans stay on the default sans (`text-2xl font-bold` for a chore name).

**Icons** are CSS masks: `<span className="hero-sun-solid size-8" />`, colored by `color`. Only these exist: `hero-sun-solid` `hero-moon-solid` `hero-star-solid` `hero-check` `hero-x-mark` `hero-lock-closed` `hero-exclamation-triangle` `hero-home` `hero-clock` `hero-gift` `hero-flag-solid`. Chore and reward icons are emoji strings (`text-[2.5rem] leading-none`). Any other glyph: inline SVG, never a text character.

**Motion** that exists: `animate-pop` (check disc springing in), `animate-sink-grow` / `animate-sink-collapse` (300ms), `active:scale-[0.97]` press, `transition-colors duration-300`.

## Rules that are already decided

Full text and rationale: `guidelines/guides/design-language.md` — read it before proposing a change to anything it covers, and say so explicitly when a design departs from it.

- Pre-reader first: signal with color, scale, count and glyph. The kids' banner carries two words, the `EARLY` and `NIGHT OWL` pills; the stake bar and standing band carry none.
- Routine chores never show a per-chore number; a routine pays one `+R`. Only extras carry `+N` / `−N` chips.
- Pending routine row = dashed slot, whole `h-24` row is the tap target, nothing in the right column. Done row = kid-color fill, `h-20`, white disc with the check in the kid's color; done rows sink below pending ones.
- Extras (optional chores, shown once the morning routine is done) sit in a `gap-2 p-2.5` group. Pending extra = dashed slot in the kid's color, `h-24 rounded-xl border-[3px] border-dashed`, no ownership border. Done extras rise to the top as one joined kid-color mass (`h-20` rows, `border-white/35` hairlines, `rounded-xl` outer corners), newest first, each with `×N` (if counted), the `+N` chip and the check disc; an undo returns the row to its authored place.
- A counted extra opens a panel in its own row: name on the left, `−` count `+` on the right (`size-16` discs, count on the default sans), a full-width `h-20 rounded-xl` button below showing `+N` only — soft green (`--paid-tint`, `--paid-edge`, `--paid-content`) at rest, solid `bg-success` with a 6px `ring-success/25` when tapped, held for 280 ms before the row lands as done. The panel keeps the slot's kid-color ground with a solid edge. Tapping the name closes it. No slider, no ✕.
- Night (23:00–05:00) is `bg-stone-950` with one evening-colored moon and nothing else.
- Five chores plus two events must fit a column without scrolling.

## Example — a pending slot above a done row

```jsx
<ul className="flex flex-col space-y-2 p-2.5">
  <li className="flex h-24 cursor-pointer select-none items-center gap-4 rounded-xl border-[3px] border-dashed px-3.5 transition-all active:scale-[0.97]"
      style={{ backgroundColor: 'var(--routine-morning-tint)', borderColor: 'var(--routine-morning-edge)' }}>
    <span className="text-[2.5rem] leading-none">🛏️</span>
    <span className="text-2xl font-bold">Make bed</span>
  </li>
</ul>
<ul className="flex flex-col">
  <li className="flex h-20 items-center gap-4 px-[27px]" style={{ backgroundColor: kid.color }}>
    <span className="text-[2.5rem] leading-none">🦷</span>
    <span className="text-2xl font-bold text-white drop-shadow-sm">Brush teeth</span>
    <span className="ml-auto flex size-9 shrink-0 items-center justify-center rounded-full bg-white drop-shadow-sm" style={{ color: kid.color }}>
      <span className="hero-check size-6" />
    </span>
  </li>
</ul>
```
