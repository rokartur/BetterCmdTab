import { createFileRoute } from "@tanstack/react-router";

import { resolveLocalePath } from "../../../../docs/i18n";
import { getLLMText, source } from "../../../../docs/source";

// `<locale?>/<slugs>/content.md`, the URL getPageMarkdownUrl builds.
export const Route = createFileRoute("/docs/llms.mdx/docs/$")({
  server: {
    handlers: {
      GET: async ({ params }) => {
        const { locale, slugs } = resolveLocalePath(params._splat);
        const page = source.getPage(slugs.slice(0, -1), locale);
        if (!page) return new Response(null, { status: 404 });
        return new Response(await getLLMText(page), {
          headers: { "Content-Type": "text/markdown" },
        });
      },
    },
  },
});
