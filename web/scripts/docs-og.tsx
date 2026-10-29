import { mkdir, readFile, writeFile } from "node:fs/promises";

// Renders the docs Open Graph cards into out/docs/og/docs/<path>image.png, the URL
// getPageImageUrl advertises. Runs after `vite build`: the prerender pass saves responses as
// text, which would corrupt a PNG.
import { frontmatter } from "fumadocs-core/content/md/frontmatter";
import { generateOGImage } from "fumadocs-ui/og/takumi";
import { googleFonts } from "takumi-js/helpers";

import { docsContentFiles } from "../src/docs/content-files";

// Takumi's bundled Geist has no Latin Extended-A, so Polish text loses ą, ł, ż. A "Geist"
// family would lose to the bundled one, so Inter. Fetched at build time, as next/og did.
const fonts = await googleFonts([{ name: "Inter", weight: [400, 800] }]);
const iconDataUri = `data:image/png;base64,${(await readFile("public/icon.png")).toString("base64")}`;

for (const { file, path } of docsContentFiles()) {
  const { title, description } = readFrontmatter(await readFile(file, "utf8"), file);
  const image = generateOGImage({
    title,
    description,
    site: "BetterCmdTab",
    // Brand accent, the dark --color-accent in src/styles.css (#3b82f6).
    primaryColor: "rgba(59,130,246,0.3)",
    primaryTextColor: "rgb(59,130,246)",
    icon: <img src={iconDataUri} alt="" width={56} height={56} />,
    fonts,
  });
  const dir = `out/docs/og/docs/${path}`;
  await mkdir(dir, { recursive: true });
  await writeFile(`${dir}image.png`, Buffer.from(await image.arrayBuffer()));
}

function readFrontmatter(source: string, file: string) {
  const { data } = frontmatter(source);
  if (
    typeof data !== "object" ||
    data === null ||
    !("title" in data) ||
    typeof data.title !== "string" ||
    !("description" in data) ||
    typeof data.description !== "string"
  ) {
    throw new Error(`${file}: frontmatter needs a string title and description`);
  }
  return { title: data.title, description: data.description };
}
