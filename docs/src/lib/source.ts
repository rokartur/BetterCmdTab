import { loader } from 'fumadocs-core/source';
import { lucideIconsPlugin } from 'fumadocs-core/source/lucide-icons';
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';
import { defineDocs } from 'fumadocs-mdx/macro';

import { defaultLocale, i18n, isLocale, localizedSegments } from './i18n';
import { docsBasePath, docsContentRoute, docsImageRoute, docsRoute, siteUrl } from './shared';

const docs = defineDocs({
  dir: 'content/docs',
  docs: {
    schema: pageSchema,
    postprocess: {
      includeProcessedMarkdown: true,
    },
  },
  meta: {
    schema: metaSchema,
  },
});

// See https://fumadocs.dev/docs/headless/source-api for more info
export const source = loader({
  baseUrl: docsRoute,
  i18n,
  source: docs.toFumadocsSource(),
  plugins: [lucideIconsPlugin()],
});

/**
 * These URLs are assembled by hand rather than produced by `next/link`, so
 * Next never applies `basePath` to them — it has to be prepended here or the
 * request lands on the marketing site at the origin root and 404s.
 *
 * `segments` also feeds route-handler `generateStaticParams`, so the locale
 * sits inside the catch-all after the fixed route rather than before it.
 */
function publicUrl(route: string, segments: string[]) {
  return docsBasePath + '/' + [...route.split('/'), ...segments].filter(Boolean).join('/');
}

/**
 * Canonical public URL of a page, absolute.
 *
 * `source` is mounted at `docsRoute` ('/'), so `page.url` carries no `/docs`
 * prefix, and Next does not apply `basePath` to metadata URLs either — so a
 * relative canonical would resolve against the origin root and point at the
 * marketing site. Fully absolute leaves nothing to infer.
 *
 * Slash-terminated to match `trailingSlash: true`, which is the form that has
 * an index.html on disk; GitHub Pages answers the bare form with its own 301.
 * Next would normalise the canonical anyway, but a canonical URL is not
 * something to leave to an implicit rewrite.
 *
 * The one exception is the English landing page: a Cloudflare URL rewrite
 * serves bare `/docs` from `/docs/index.html`, so that is its public URL.
 * Next's metadata resolver re-appends the slash under `trailingSlash`, so the
 * `build` script strips it from the exported HTML again.
 */
export function getPageUrl(page: (typeof source)['$inferPage']) {
  if (page.url === '/') return siteUrl + docsBasePath;
  return siteUrl + docsBasePath + (page.url.endsWith('/') ? page.url : `${page.url}/`);
}

export function getPageAlternates(page: (typeof source)['$inferPage']) {
  const languages: Record<string, string> = {};

  for (const locale of i18n.languages) {
    const translation = source.getPage(page.slugs, locale);
    if (translation) languages[locale] = getPageUrl(translation);
  }

  languages['x-default'] = languages[defaultLocale];
  return languages;
}

export function getPageImageUrl(page: (typeof source)['$inferPage']) {
  const segments = localizedSegments(page.locale, [...page.slugs, 'image.png']);

  return { segments, url: publicUrl(docsImageRoute, segments) };
}

export function getPageMarkdownUrl(page: (typeof source)['$inferPage']) {
  const segments = localizedSegments(page.locale, [...page.slugs, 'content.md']);

  return { segments, url: publicUrl(docsContentRoute, segments) };
}

export function canonicalizeLLMLinks(markdown: string, locale?: string) {
  return markdown.replace(/\]\((\/(?!\/)[^)\s]*)\)/g, (_link, href: string) => {
    const suffixStart = href.search(/[?#]/);
    const pathname = suffixStart === -1 ? href : href.slice(0, suffixStart);
    const suffix = suffixStart === -1 ? '' : href.slice(suffixStart);
    const slugs = pathname.split('/').filter(Boolean);
    const prefixedLocale = slugs[0];
    let targetLocale = isLocale(locale) ? locale : defaultLocale;

    if (isLocale(prefixedLocale)) {
      targetLocale = prefixedLocale;
      slugs.shift();
    }

    const page = source.getPage(slugs.length === 0 ? undefined : slugs, targetLocale);
    if (!page) throw new Error(`LLM export contains an unknown docs link: ${href}`);

    return `](${getPageUrl(page)}${suffix})`;
  });
}

export async function getLLMText(page: (typeof source)['$inferPage']) {
  const processed = await page.data.getText('processed');

  return `# ${page.data.title} (${getPageUrl(page)})

${canonicalizeLLMLinks(processed, page.locale)}`;
}
