import { createFileRoute, notFound } from "@tanstack/react-router";
import { DocsLayout } from "fumadocs-ui/layouts/docs";
import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
  MarkdownCopyButton,
  ViewOptionsPopover,
} from "fumadocs-ui/layouts/docs/page";
import { use } from "react";

import { configReferenceToc } from "../../docs/config-reference";
import { DocsProvider } from "../../docs/DocsProvider";
import { defaultLocale, messages, resolveLocalePath, type Locale } from "../../docs/i18n";
import { baseOptions } from "../../docs/layout";
import { getMDXComponents } from "../../docs/mdx";
import {
  getPageAlternates,
  getPageImageUrl,
  getPageMarkdownUrl,
  getPageUrl,
  gitConfig,
  siteUrl,
  source,
} from "../../docs/source";

import docsCss from "../../docs/docs.css?url";

// Page whose ToC is generated rather than extracted from MDX headings; rename with the file.
const CONFIG_REFERENCE_SLUG = "config-reference";

export const Route = createFileRoute("/docs/$")({
  // Keeps `source` (every page's frontmatter) out of the marketing pages' entry chunk.
  codeSplitGroupings: [["loader", "component"]],
  loader: async ({ params }) => {
    const { page, locale } = findPage(params._splat);
    await page.data.preload();
    return {
      locale,
      title: page.data.title,
      description: page.data.description ?? "",
      url: getPageUrl(page),
      alternates: getPageAlternates(page),
      image: siteUrl + getPageImageUrl(page),
    };
  },
  head: ({ loaderData }) => (loaderData ? pageHead(loaderData) : {}),
  component: DocsRoute,
});

function findPage(splat: string | undefined) {
  const { locale, slugs } = resolveLocalePath(splat);
  const page = source.getPage(slugs, locale);
  if (!page) throw notFound();
  return { page, locale };
}

function pageHead(page: {
  locale: Locale;
  title: string;
  description: string;
  url: string;
  alternates: Record<string, string>;
  image: string;
}) {
  const siteName = messages[page.locale].Metadata.siteName;
  return {
    meta: [
      { title: `${page.title} · BetterCmdTab` },
      { name: "description", content: page.description },
      { name: "color-scheme", content: "light dark" },
      { property: "og:type", content: "article" },
      { property: "og:site_name", content: siteName },
      { property: "og:title", content: page.title },
      { property: "og:description", content: page.description },
      { property: "og:url", content: page.url },
      { property: "og:locale", content: page.locale === defaultLocale ? "en_US" : "pl_PL" },
      { property: "og:image", content: page.image },
      { name: "twitter:card", content: "summary_large_image" },
    ],
    links: [
      { rel: "stylesheet", href: docsCss },
      { rel: "canonical", href: page.url },
      ...Object.entries(page.alternates).map(([hrefLang, href]) => ({
        rel: "alternate",
        hrefLang,
        href,
      })),
      { rel: "icon", href: "/favicon-32.png", type: "image/png", sizes: "32x32" },
      { rel: "icon", href: "/favicon-16.png", type: "image/png", sizes: "16x16" },
      { rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
    ],
  };
}

function DocsRoute() {
  const { page, locale } = findPage(Route.useParams()._splat);
  const { body: MDX, toc: extractedToc } = use(page.data.load());
  const markdownUrl = getPageMarkdownUrl(page);
  // The reference page's headings are rendered by <ConfigReference />, so they never reach
  // the MDX source fumadocs extracts the ToC from.
  const toc =
    page.slugs.join("/") === CONFIG_REFERENCE_SLUG
      ? [...extractedToc, ...configReferenceToc(locale)]
      : extractedToc;

  return (
    <DocsProvider locale={locale} slugs={page.slugs}>
      <div className="flex min-h-screen flex-col">
        <DocsLayout tree={source.getPageTree(locale)} {...baseOptions(locale)}>
          <DocsPage toc={toc} full={page.data.full}>
            <DocsTitle>{page.data.title}</DocsTitle>
            <DocsDescription className="mb-0">{page.data.description}</DocsDescription>
            <div className="flex flex-row items-center gap-2 border-b pb-6">
              <MarkdownCopyButton markdownUrl={markdownUrl} />
              <ViewOptionsPopover
                markdownUrl={markdownUrl}
                githubUrl={`https://github.com/${gitConfig.user}/${gitConfig.repo}/blob/${gitConfig.branch}/web/content/docs/${page.path}`}
              />
            </div>
            <DocsBody>
              <MDX components={getMDXComponents(locale)} />
            </DocsBody>
          </DocsPage>
        </DocsLayout>
      </div>
    </DocsProvider>
  );
}
