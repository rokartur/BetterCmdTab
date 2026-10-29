# Contributing to the site

`web/` is the BetterCmdTab website: the marketing pages at `/` and the documentation at
`/docs`, one [TanStack Start](https://tanstack.com/start) app prerendered to static
files. The docs pages are [Fumadocs](https://fumadocs.dev) (`fumadocs-mdx`, `fumadocs-ui`).

For contributing to the **app**, see [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

```bash
cd web
bun install
bun run dev          # http://localhost:3000, docs at http://localhost:3000/docs/
```

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
| `src/routes/` | Marketing pages, plus `docs/`: the docs page route and its static exports. |
| `content/docs/en/*.mdx` | English docs pages. |
| `content/docs/pl/*.mdx` | Polish pages with matching English filenames. |
| `content/docs/{en,pl}/meta.json` | Localized sidebar order and section separators. |
| `src/docs/source.ts` | The Fumadocs source, page URLs, sidebar icons. |
| `src/docs/config-reference.ts` | Section grouping + defaults for the config reference. |
| `src/docs/ConfigReference.tsx` | Renders the reference tables. |
| `src/docs/config-schema.json` | **Generated** — a copy of the app's own `schema.json`. |
| `src/docs/messages.{en,pl}.json` | Docs UI strings (nav, metadata, reference tables). |
| `src/docs/layout.tsx` | Nav, sidebar footer links, logo. |
| `src/docs/docs.css` | Docs palette, mirrored from `src/styles.css`. |
| `scripts/docs-og.tsx` | Renders the docs Open Graph images after `vite build`. |

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
4. List both URLs in `web/public/sitemap.xml`, slashed (`/docs/my-page/`,
   `/docs/pl/my-page/`). The sitemap is hand-maintained and CI fails on a page
   it does not list.

**`icon` must be in `pageIcons` in `src/docs/source.ts`.** Only those Lucide icons
ship, because the source also runs in the browser; an unknown name fails the build.

**Keep `description` to Latin and Polish characters.** The OG image renderer
(`scripts/docs-og.tsx`) loads Inter from Google Fonts, and a glyph Inter lacks, such as
`⌘`, renders as a box. Write `Command-Tab` in frontmatter; use `⌘` freely in the body.

## URLs and links

English pages live at `/docs/<slug>/`, Polish at `/docs/pl/<slug>/`. The router uses
`trailingSlash: 'always'`, and every page ships as `<slug>/index.html`, so the slashed
URL is the one that exists; `serve.ts` 301s the bare form.

**Links in content are full paths, in the page's language:** `/docs/configuration/`
in an English page, `/docs/pl/configuration/` in a Polish one. Nothing rewrites them,
and CI fails a Polish page that links into the English tree.

`source.ts` passes its own `url` to the Fumadocs loader: the default would put the
locale before the base (`/pl/docs/<slug>`).

## Components available in MDX

`Callout`, `Cards` / `Card`, `Tabs` / `Tab`, `Files`, plus two of ours:

```mdx
<ConfigReference />              {/* every config key, grouped */}
<ConfigObject name="appExceptions" />   {/* one array-of-objects key */}
```

Anything else must be registered in `src/docs/mdx.tsx` first — an unregistered
component fails the prerender of the page that uses it.

## The config reference is generated — do not hand-edit it

`/docs/config-reference/` is built from `src/docs/config-schema.json`, which is a
verbatim copy of the `schema.json` BetterCmdTab writes next to `config.json`.
Types, descriptions, enum values and ranges all come from the app, so they cannot
drift from what it actually accepts.

After a preference is added or changed in the app, run it once so it rewrites the
schema, then refresh the copy:

```bash
cp ~/.config/bettercmdtab/schema.json web/src/docs/config-schema.json
```

Two things are *not* in the schema and are maintained by hand in
`src/docs/config-reference.ts`:

- **`sections`** — which group a key appears under.
- **`defaults`** — the value shown in the Default column, transcribed from
  `reloadFromDefaults()`.

`bun run build` fails while a schema key is missing from `sections`, or a key
outside the Legacy section is missing from `defaults`. The error names the keys.

Note the schema is generated from *a* Mac: `enumDescriptions` are localized, and
`commitSoundName`'s allowed values come from that machine's
`/System/Library/Sounds`. Refresh it from an English system.

## Styling

The marketing pages load `src/styles.css`; docs pages load `src/docs/docs.css`
instead (the root route's `head` picks one), so the two never share base styles.
The docs palette mirrors `src/styles.css` token-for-token so the two read as one
site; the mapping onto Fumadocs' variables is at the top of `docs.css`. **If you
change a colour, change it in both files.**

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
in a whole-paragraph diff and doubles the noise on every en/pl pair. `build` is the
one that catches unregistered MDX components, unknown icons and a schema key
missing from the reference.

Preview the real production output, not just the dev server:

```bash
bun run build && bun serve.ts   # serves out/ on :3000
```

## How it ships

`Dockerfile` builds `web/` and serves `out/` with `serve.ts`, deployed on vexdock.
There is no server-side rendering at runtime and no reverse proxy.

`serve.ts` serves files: a slashed URL gets `<path>/index.html`, a bare
directory 301s to its slashed form, `/pl/*` 301s to `/docs/pl/*`, anything
missing gets `404.html`, and only hashed assets (a year), media (a week) and
HTML (`no-cache`) get `Cache-Control`.
Anything that would be a server rule is a property of the built tree instead:

- Every page in `pages` (`vite.config.ts`) is prerendered; the docs pages and their
  Markdown twins are listed from `content/docs`. `/404` is prerendered with
  `autoSubfolderIndex: false` because `serve.ts` serves that exact filename.
- The search index (`/docs/api/search`), `llms.txt`, `llms-full.txt` and the
  per-page `content.md` files are server routes, prerendered into plain files.
- OG images are binary, which the prerender pass would write as text, so
  `scripts/docs-og.tsx` renders them after `vite build`.
- `public/sitemap.xml` is hand-maintained; CI checks it both ways: every URL
  resolves to a real `index.html`, and every `content/docs/*/*.mdx` is listed.

`.github/workflows/ci-site.yml` runs the same build on every PR plus the checks above.

## Style

- British-neutral English, second person, present tense.
- Prefer a table or a short example over a paragraph.
- Code blocks get a language, and a `title=` when the path matters:
  ` ```json title="config.json" `.
- Link the first mention of a concept to its page; don't re-link every mention.
- Say what something *does*, not that it is "simply" or "just" anything.
