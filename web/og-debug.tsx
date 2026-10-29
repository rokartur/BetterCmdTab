import { googleFonts } from "takumi-js/helpers";
import { ImageResponse } from "takumi-js/response";
import { writeFile } from "node:fs/promises";
const fonts = await googleFonts([{ name: "Inter", weight: [400, 800] }]);
console.log(fonts.length, JSON.stringify(fonts.slice(0, 3)).slice(0, 400));
for (const [name, opts] of [["a", { fonts }], ["b", { fonts, fontFamilies: ["Inter"] }]] as const) {
  const r = new ImageResponse(<div style={{ display: "flex", fontFamily: "Inter", fontSize: 60, color: "black", background: "white", width: "100%", height: "100%" }}>Zażółć gęślą jaźń</div>, { width: 800, height: 200, ...opts });
  await writeFile(`og-debug-${name}.png`, Buffer.from(await r.arrayBuffer()));
}
