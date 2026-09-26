// Generates the stub package's stylesheets from the app's compiled CSS, so
// the sync never carries a hand-maintained copy of the tokens or fonts.
// Run from the repo root after `mix tailwind bear_cub` (see buildCmd).
//
// The @font-face blocks are split into their own file because the converter
// only follows font url()s out of the package dir from an `extraFonts` CSS,
// never from `cssEntry`; their root-absolute /fonts/ urls are pointed at the
// real files in priv/static/fonts so the converter can copy them.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';

const css = readFileSync('priv/static/assets/css/app.css', 'utf8');
const faces = css.match(/@font-face\s*\{[^}]+\}/g) ?? [];
if (!faces.length) throw new Error('no @font-face in compiled app.css — did the Nunito block move?');

writeFileSync(
  '.design-sync/pkg/fonts.css',
  faces.join('\n').replaceAll('url("/fonts/', 'url("../../priv/static/fonts/') + '\n',
);
writeFileSync('.design-sync/pkg/styles.css', faces.reduce((s, f) => s.replace(f, ''), css));

// docs/design-language.org is the binding source for kids' view semantics,
// invariants and rulings; the converter only ships markdown guidelines, so
// this is a lossy one-way rendering of it — headings, inline code, bold, and
// links flattened to their labels. Never edit the output.
const md = readFileSync('docs/design-language.org', 'utf8')
  .split('\n')
  .filter((l) => !/^#\+(startup|date):/i.test(l))
  .map((l) =>
    l
      .replace(/^#\+title:\s*(.*)$/i, '# $1')
      .replace(/^(\*+) /, (_, stars) => '#'.repeat(stars.length + 1) + ' ')
      .replace(/\[\[[^\]]*\]\[([^\]]*)\]\]/g, '$1')
      .replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s.,;:)]|$)/g, '$1**$2**')
      .replace(/(^|[\s(—/])[~=]([^~=\n]+)[~=](?=[\s.,;:)—/]|$)/g, '$1`$2`'),
  )
  .join('\n');
mkdirSync('.design-sync/pkg/guides', { recursive: true });
writeFileSync('.design-sync/pkg/guides/design-language.md', md);

console.log(`design-sync: guides/design-language.md, styles.css + fonts.css (${faces.length} @font-face) written`);
