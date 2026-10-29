import { createFileRoute } from "@tanstack/react-router";

import { getLLMText, source } from "../../docs/source";

export const Route = createFileRoute("/docs/llms-full.txt")({
  server: {
    handlers: {
      GET: async () => {
        const texts = await Promise.all(source.getPages().map(getLLMText));
        return new Response(texts.join("\n\n"));
      },
    },
  },
});
