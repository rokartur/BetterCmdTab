import { createFileRoute } from "@tanstack/react-router";
import { llms } from "fumadocs-core/source";

import { canonicalizeLLMLinks, source } from "../../docs/source";

export const Route = createFileRoute("/docs/llms.txt")({
  server: {
    handlers: {
      GET: async () => new Response(canonicalizeLLMLinks(await llms(source).index())),
    },
  },
});
