# Contributing to the documentation

This directory is the BetterCmdTab documentation site — [Next.js](https://nextjs.org)
+ [Fumadocs](https://fumadocs.dev), deployed to `bettercmdtab.app/docs`.

For contributing to the **app**, see [`../CONTRIBUTING.md`](../CONTRIBUTING.md).
This file is only about the docs.

```bash
cd docs
bun install
bun run dev          # http://localhost:3000/docs
```

> The dev server lives at **`/docs`**, not `/`. That prefix is real (see
> [Routing](#routing-the-docs-prefix)) — `http://localhost:3000` alone 404s.

---

## The one rule: never state anything you have not verified

Most of this site describes exactly what the Swift app does — defaults, key names,
timings, which permission gates what. Every one of those claims is checkable, so
check it. A wrong default in a reference table is worse than no table: the reader
has no reason to doubt it.

Before writing or changing a factual claim, open the source:

| Claim about | Verify in |
| --- | --- |
| A preference's default | `BetterCmdTab/App/Preferences.swift` → `reloadFromDefaults()` |
| A key name, type, range, allowed values | `BetterCmdTab/App/ConfigSchemaDocs.swift` |
| Config-file behaviour (sync, watching, errors) | `BetterCmdTab/App/ConfigFile.swift` |
| Export/import, what is excluded | `BetterCmdTab/App/SettingsPortability.swift` |
| A permission or UI string | `BetterCmdTab/Settings/*ViewController.swift` |

A real example of why: the config file was documented as containing "all 85 keys".
It doesn't — `flatSettingsSnapshot()` only emits keys actually present in
`UserDefaults`, and every `didSet` is guarded with `guard oldValue != …`, so
unchanged settings are never written. A real file has ~60. That took one look at
the source to settle, and shipping it would have confused every reader who counted.

If you cannot verify a claim, write the weaker sentence that is true.

---

## Where things live

| Path | What it is |
| --- | --- |
| `content/docs/en/*.mdx` | English pages. |
| `content/docs/pl/*.mdx` | Polish pages with matching English filenames. |
| `content/docs/{en,pl}/meta.json` | Localized sidebar order and section separators. |
| `src/lib/config-reference.ts` | Section grouping + defaults for the config reference. |
| `src/components/config-reference.tsx` | Renders the reference tables. |
| `src/data/config-schema.json` | **Generated** — a copy of the app's own `schema.json`. |
| `src/lib/layout.shared.tsx` | Nav, sidebar footer links, logo. |
| `src/app/global.css` | Palette, mirrored from `web/app/globals.css`. |

## Adding a page

1. Create `content/docs/en/my-page.mdx` with frontmatter:

   ```mdx
   ---
   title: My page
   description: One sentence. It becomes the meta description and the OG card text.
   icon: Rocket
   ---
   ```

2. Add it to `content/docs/en/meta.json` — pages are ordered by that list, not
   alphabetically. `"---Label---"` inserts a section heading.
3. Add the Polish translation as `content/docs/pl/my-page.mdx` and add the same
   slug to `content/docs/pl/meta.json`. The build intentionally has no language
   fallback: a missing translation must fail visibly rather than publish English
   under `/pl`.

**`icon` must exist in Fumadocs' Lucide set.** It is not the full `lucide-react`
export; `FileJson` for example resolves in the package but the build logs
`Unknown icon detected: FileJson` and renders nothing. Check the build output
after adding one.

**Avoid `⌘` and other exotic glyphs in `description`.** The OG image renderer
fetches fonts per-glyph and fails on them (`Failed to load dynamic font for ⌘`),
leaving a blank box in the social card. Write `Command-Tab` in frontmatter; use
`⌘` freely in the body.

## Routing: the `/docs` prefix

The site is served at `bettercmdtab.app/docs`, which `next.config.mjs` implements
with `basePath: '/docs'`. Next adds that prefix to everything **it** generates, so:

- **Internal links are written without it.** Link to `/configuration`, and the
  reader gets `/docs/configuration`. Writing `/docs/configuration` produces
  `/docs/docs/configuration`.
- **Raw URLs are not rewritten.** A plain `<img src>` or `fetch()` bypasses Next,
  so those must prepend `docsBasePath` from `src/lib/shared.ts` by hand. The
  search client is exactly this case — it is passed an explicit `api` URL in
  `src/components/docs-provider.tsx` because its own default would resolve to
  `/api/search` and hit the marketing site.

`docsRoute` in `src/lib/shared.ts` is `/` for the same reason: it is an internal
route, and `basePath` supplies the public prefix.

English keeps the existing `/docs/<slug>/` URLs; Polish is materialized at
`/docs/pl/<slug>/`. There is no locale middleware — GitHub Pages cannot run one.
The MDX renderer keeps ordinary Markdown links in the current page's language. Raw
component props such as `<Card href>` bypass that resolver, so Polish cards must
use `/pl/<slug>` (still without the `/docs` base path).

## Components available in MDX

`Callout`, `Cards` / `Card`, `Tabs` / `Tab`, `Files`, plus two of ours:

```mdx
<ConfigReference />              {/* every config key, grouped */}
<ConfigObject name="appExceptions" />   {/* one array-of-objects key */}
```

Anything else must be registered in `src/components/mdx.tsx` first — an
unregistered component fails the build with *"Expected component `X` to be
defined"*, and only on the page that uses it.

## The config reference is generated — do not hand-edit it

`/docs/config-reference` is built from `src/data/config-schema.json`, which is a
verbatim copy of the `schema.json` BetterCmdTab writes next to `config.json`.
Types, descriptions, enum values and ranges all come from the app, so they cannot
drift from what it actually accepts.

After a preference is added or changed in the app, run it once so it rewrites the
schema, then refresh the copy:

```bash
cp ~/.config/bettercmdtab/schema.json docs/src/data/config-schema.json
```

Two things are *not* in the schema and are maintained by hand in
`src/lib/config-reference.ts`:

- **`sections`** — which group a key appears under.
- **`defaults`** — the value shown in the Default column, transcribed from
  `reloadFromDefaults()`.

A key missing from both still renders: it lands in an **"Other"** section with an
unknown default. That is deliberate — a new preference shows up as visibly
unsorted instead of silently vanishing. If you see "Other" on the built page,
something needs grouping.

Note the schema is generated from *a* Mac: `enumDescriptions` are localized, and
`commitSoundName`'s allowed values come from that machine's
`/System/Library/Sounds`. Refresh it from an English system.

## Styling

The palette mirrors `web/app/globals.css` token-for-token so the landing page and
the docs read as one site; the mapping onto Fumadocs' variables is at the top of
`src/app/global.css`. **If you change a colour, change it in both files.**

The site is dark-only, matching the marketing site — `next-themes` and the theme
switch are both disabled. Do not reintroduce a light palette in one place only.

## Before you open a PR

```bash
bun run lint
bun run format:check
bun run types:check
bun run build
```

All four must pass (`bun run format` fixes the second).
The formatter skips `content/` and this file: prose is wrapped by hand, and
oxfmt rewraps paragraphs and aligns table pipes, which buries a one-word edit
in a whole-paragraph diff and doubles the noise on every en/pl pair. `build` is the one that catches unknown icons, unregistered
MDX components and broken links into generated anchors.

Worth checking by eye on the built output:

- **Anchors resolve.** Section anchors are slugified (`Display & timing` →
  `#display-timing`, one dash), and reference rows anchor on the *key name*
  (`#revealDelayMs`). Prefer linking the key — it survives a section rename.
- **No "Other" section** appeared in the config reference.
- **Search works.** It is a static index (`out/api/search`) built at compile time,
  not a live endpoint.

Preview the real production output, not just the dev server:

```bash
bun run build && bun run preview   # serves out/ — note there is no `next start`
```

`next start` does not exist here: the site is `output: 'export'`, a pile of static
files with no server at runtime.

## How it ships

`web/Dockerfile` builds `web/` and `docs/`, copies this export into
`web/out/docs`, and serves the merged tree with `web/serve.ts`, deployed on
vexdock. There is no separate docs service and no reverse proxy.

That means a docs change reaches production through the same artifact as a
marketing change — and that `bun run build` failing here fails the whole site's
deploy. `.github/workflows/ci-site.yml` runs the same builds on every PR, plus
the checks that used to be server rules: every sitemap URL resolves to a real
`index.html`, no internal link points at a URL Pages would redirect, and
`robots.txt` still blocks the RSC payload twins.

## Style

- British-neutral English, second person, present tense.
- Prefer a table or a short example over a paragraph.
- Code blocks get a language, and a `title=` when the path matters:
  ` ```json title="config.json" `.
- Link the first mention of a concept to its page; don't re-link every mention.
- Say what something *does*, not that it is "simply" or "just" anything.
