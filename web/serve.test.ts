/// <reference types="bun" />
import { expect, test } from "bun:test";

import { markdownCanonical } from "./serve";

test("a docs markdown export points at its HTML page", () => {
  expect(markdownCanonical("/docs/llms.mdx/docs/content.md")).toBe("https://bettercmdtab.app/docs");
  expect(markdownCanonical("/docs/llms.mdx/docs/pl/config-reference/content.md")).toBe(
    "https://bettercmdtab.app/docs/pl/config-reference",
  );
});

test("other files get no canonical", () => {
  expect(markdownCanonical("/docs/llms.txt")).toBeUndefined();
  expect(markdownCanonical("/docs/app-rules")).toBeUndefined();
});
