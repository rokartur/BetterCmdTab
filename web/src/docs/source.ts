import { loader } from "fumadocs-core/source";
import { metaSchema, pageSchema } from "fumadocs-core/source/schema";
import { defineDocs } from "fumadocs-mdx/macro";
import { AppWindow, Braces, GitPullRequest, Keyboard, List, Rocket } from "lucide-react";
import { createElement } from "react";

import { defaultLocale, i18n, localizedSegments } from "./i18n";

export const siteUrl = "https://bettercmdtab.app";

export const gitConfig = {
  user: "rokartur",
  repo: "BetterCmdTab",
  branch: "main",
};

const docs = defineDocs({
  dir: "content/docs",
  docs: {
    async: true,
    schema: pageSchema,
    postprocess: {
      includeProcessedMarkdown: true,
    },
  },
  meta: {
    schema: metaSchema,
  },
});

// Slash-terminated: every page ships as <dir>/index.html, and web/serve.ts 301s the bare form.
// fumadocs strips the slash from `page.url`; the router's `trailingSlash` puts it back on links.
export function docsPath(slugs: string[], locale: string | undefined) {
  return `/${["docs", ...localizedSegments(locale, slugs)].join("/")}/`;
}

// The frontmatter `icon` names. Only these ship: fumadocs' lucideIconsPlugin bundles every
// Lucide icon (~650 KB) into the client, where this source also runs.
const pageIcons = new Map(
  Object.entries({ AppWindow, Braces, GitPullRequest, Keyboard, List, Rocket }),
);

export const source = loader({
  baseUrl: "/docs",
  // The default puts the locale before the base: /pl/docs/<slug>.
  url: docsPath,
  i18n,
  source: docs.toFumadocsSource(),
  icon: (name) => {
    if (name === undefined) return;
    const icon = pageIcons.get(name);
    if (!icon) throw new Error(`Unknown docs icon "${name}": add it to pageIcons in source.ts`);
    return createElement(icon);
  },
});

type Page = (typeof source)["$inferPage"];

/** Canonical public URL of a page, absolute. */
export function getPageUrl(page: Page) {
  return siteUrl + docsPath(page.slugs, page.locale);
}

export function getPageAlternates(page: Page) {
  const languages: Record<string, string> = {};

  for (const locale of i18n.languages) {
    const translation = source.getPage(page.slugs, locale);
    if (translation) languages[locale] = getPageUrl(translation);
  }

  languages["x-default"] = languages[defaultLocale];
  return languages;
}

function routeUrl(route: string, page: Page, file: string) {
  return `/${[route, ...localizedSegments(page.locale, page.slugs), file].join("/")}`;
}

/** Written to disk by scripts/docs-og.tsx, which mirrors this path. */
export function getPageImageUrl(page: Page) {
  return routeUrl("docs/og/docs", page, "image.png");
}

export function getPageMarkdownUrl(page: Page) {
  return routeUrl("docs/llms.mdx/docs", page, "content.md");
}

// Markdown links and JSX `href` props (the <Card> grids) both reach the export verbatim.
const ROOT_RELATIVE_LINK = /(\]\(|href=")(\/(?!\/)[^)"\s#?]*)/g;

/** The machine-readable exports are read off-site, so root-relative links become absolute and slashed. */
export function canonicalizeLLMLinks(markdown: string) {
  return markdown.replace(
    ROOT_RELATIVE_LINK,
    (_link, opener: string, path: string) =>
      `${opener}${siteUrl}${path.endsWith("/") ? path : `${path}/`}`,
  );
}

export async function getLLMText(page: Page) {
  const processed = await page.data.getText("processed");

  return `# ${page.data.title} (${getPageUrl(page)})

${canonicalizeLLMLinks(processed)}`;
}
