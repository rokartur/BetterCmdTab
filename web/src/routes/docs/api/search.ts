import { createFileRoute } from "@tanstack/react-router";
import { createFromSource } from "fumadocs-core/search/server";

import { source } from "../../../docs/source";

// Prerendered into one JSON file that the client searches in the browser; there is no server.
const search = createFromSource(source);

export const Route = createFileRoute("/docs/api/search")({
  server: { handlers: { GET: () => search.staticGET() } },
});
