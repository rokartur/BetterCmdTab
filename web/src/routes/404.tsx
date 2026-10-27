import { createFileRoute } from "@tanstack/react-router";

import { NotFound } from "./__root";

// Exists purely so the prerender pass has a route to render into 404.html; nothing links
// here. See `pages` in vite.config.ts.
export const Route = createFileRoute("/404")({
  head: () => ({
    meta: [{ title: "Page not found · BetterCmdTab" }, { name: "robots", content: "noindex" }],
  }),
  component: NotFound,
});
