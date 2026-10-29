import { readdirSync } from "node:fs";
import { join } from "node:path";

/**
 * Every content/docs/<locale>/<slug>.mdx with its path under /docs: English at `<slug>/`,
 * other locales at `<locale>/<slug>/`, and `index` at the locale's root. Build-time only.
 */
export function docsContentFiles() {
  const files: { file: string; path: string }[] = [];
  for (const entry of readdirSync("content/docs", { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const locale = entry.name;
    for (const name of readdirSync(join("content/docs", locale))) {
      if (!name.endsWith(".mdx")) continue;
      const slug = name.slice(0, -".mdx".length);
      const path = (locale === "en" ? "" : `${locale}/`) + (slug === "index" ? "" : `${slug}/`);
      files.push({ file: join("content/docs", locale, name), path });
    }
  }
  return files;
}
