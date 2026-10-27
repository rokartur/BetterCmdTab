import babel from "@rolldown/plugin-babel";
import tailwindcss from "@tailwindcss/vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import viteReact, { reactCompilerPreset } from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Static site: every route in `pages` is prerendered, no server at runtime. serve.ts serves
// the tree as plain files (see Dockerfile), and the
// docs export (../docs, still Next with basePath=/docs) is merged into `out/docs`
// afterwards so the two static trees share one origin.
export default defineConfig({
  plugins: [
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
      ],
      // crawlLinks would follow the /docs/* links into the other app, which
      // this build has no routes for.
      prerender: { enabled: true, crawlLinks: false, failOnError: true },
      // web/public/sitemap.xml is hand-maintained and covers the docs pages
      // too, which this build knows nothing about. Generating one here would
      // overwrite it with a single entry.
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
