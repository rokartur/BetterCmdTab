import babel from "@rolldown/plugin-babel";
import tailwindcss from "@tailwindcss/vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import viteReact, { reactCompilerPreset } from "@vitejs/plugin-react";
import { fumadocsMdx } from "fumadocs-mdx/vite";
import { defineConfig } from "vite";

import { docsContentFiles } from "./src/docs/content-files";

const docsPages = docsContentFiles().flatMap(({ path }) => [
  { path: `/docs/${path}` },
  { path: `/docs/llms.mdx/docs/${path}content.md` },
]);

// Static site: every route in `pages` is prerendered, no server at runtime. serve.ts serves
// the tree as plain files (see Dockerfile). Docs OG images are binary, which the prerender
// pass writes as text, so scripts/docs-og.tsx renders those after the build.
export default defineConfig({
  plugins: [
    fumadocsMdx(),
    tailwindcss(),
    tanstackStart({
      pages: [
        { path: "/" },
        { path: "/alttab-alternative/" },
        { path: "/cmd-tab-mac/" },
        // serve.ts answers any unknown path with /404.html, so the not-found
        // route is prerendered to that exact filename rather than the default
        // /404/index.html subfolder.
        { path: "/404", prerender: { autoSubfolderIndex: false } },
        ...docsPages,
        { path: "/docs/api/search" },
        { path: "/docs/llms.txt" },
        { path: "/docs/llms-full.txt" },
      ],
      // `pages` is the complete list; a crawl would only rediscover it.
      prerender: { enabled: true, crawlLinks: false, failOnError: true },
      // web/public/sitemap.xml is hand-maintained; generating one here would overwrite it.
      sitemap: { enabled: false },
    }),
    viteReact(),
    babel({ presets: [reactCompilerPreset()] }),
  ],
  // `out/` is the deployable tree serve.ts serves, so the client
  // build owns it outright; the SSR bundle is only a build-time input to the
  // prerender pass and stays out of the artifact.
  environments: {
    client: { build: { outDir: "out" } },
    ssr: { build: { outDir: ".tanstack/server" } },
  },
});
