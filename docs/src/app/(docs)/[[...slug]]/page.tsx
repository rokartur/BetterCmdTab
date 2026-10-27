import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
  MarkdownCopyButton,
  ViewOptionsPopover,
} from 'fumadocs-ui/layouts/docs/page';
import { createRelativeLink } from 'fumadocs-ui/mdx';
import type { Metadata } from 'next';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { notFound } from 'next/navigation';

import { getMDXComponents } from '@/components/mdx';
import { configReferenceToc } from '@/lib/config-reference';
import { defaultLocale, localizedSegments, resolveLocalePath } from '@/lib/i18n';
import { appName, gitConfig } from '@/lib/shared';
import {
  getPageAlternates,
  getPageImageUrl,
  getPageMarkdownUrl,
  getPageUrl,
  source,
} from '@/lib/source';

/** Page whose ToC is generated rather than extracted from MDX headings. */
const CONFIG_REFERENCE_SLUG = 'config-reference';

type Props = { params: Promise<{ slug?: string[] }> };

export const dynamicParams = false;

export default async function Page(props: Props) {
  const params = await props.params;
  const { locale, slugs } = resolveLocalePath(params.slug);
  const page = source.getPage(slugs, locale);
  if (!page) notFound();

  setRequestLocale(locale);
  const MDX = page.data.body;
  const Link = createRelativeLink(source, page);
  const markdownUrl = getPageMarkdownUrl(page).url;
  // The reference page's headings are rendered by <ConfigReference />, so they
  // never reach the MDX source fumadocs extracts the ToC from — supply them here.
  // Coupled to the file name by CONFIG_REFERENCE_SLUG; rename both together.
  const toc =
    page.slugs.length === 1 && page.slugs[0] === CONFIG_REFERENCE_SLUG
      ? [...page.data.toc, ...(await configReferenceToc(locale))]
      : page.data.toc;

  return (
    <DocsPage toc={toc} full={page.data.full}>
      <DocsTitle>{page.data.title}</DocsTitle>
      <DocsDescription className="mb-0">{page.data.description}</DocsDescription>
      <div className="flex flex-row items-center gap-2 border-b pb-6">
        <MarkdownCopyButton markdownUrl={markdownUrl} />
        <ViewOptionsPopover
          markdownUrl={markdownUrl}
          // The docs site is a subdirectory of the repo, so the content path
          // needs the `docs/` prefix or every link 404s.
          githubUrl={`https://github.com/${gitConfig.user}/${gitConfig.repo}/blob/${gitConfig.branch}/docs/content/docs/${page.path}`}
        />
      </div>
      <DocsBody>
        <MDX
          components={getMDXComponents({
            // Fumadocs resolves relative file links, while this static export
            // also needs absolute app routes to keep the current locale.
            a: ({ href, ...props }) => (
              <Link
                {...props}
                href={
                  locale !== defaultLocale &&
                  href?.startsWith('/') &&
                  !href.startsWith('//') &&
                  href !== `/${locale}` &&
                  !href.startsWith(`/${locale}/`)
                    ? `/${locale}${href}`
                    : href
                }
              />
            ),
          })}
        />
      </DocsBody>
    </DocsPage>
  );
}

export function generateStaticParams() {
  return source.generateParams().map(({ lang, slug }) => ({
    slug: localizedSegments(lang, slug),
  }));
}

export async function generateMetadata(props: Props): Promise<Metadata> {
  const params = await props.params;
  const { locale, slugs } = resolveLocalePath(params.slug);
  const page = source.getPage(slugs, locale);
  if (!page) notFound();

  // og:url has no canonical fallback in Next and must be set too.
  const url = getPageUrl(page);
  const t = await getTranslations({ locale, namespace: 'Metadata' });

  return {
    // The layout's title.template applies only to segments below it, never to this page.
    title: { absolute: `${page.data.title} · ${appName}` },
    description: page.data.description,
    alternates: {
      canonical: url,
      languages: getPageAlternates(page),
    },
    // Next replaces the layout's openGraph object whole, so the page sets every field itself.
    openGraph: {
      type: 'article',
      siteName: t('siteName'),
      title: page.data.title,
      description: page.data.description,
      url,
      locale: locale === defaultLocale ? 'en_US' : 'pl_PL',
      images: getPageImageUrl(page).url,
    },
  };
}
