/**
 * Writes releases.json, the release snapshot the page renders until (or, when rate-limited,
 * instead of) the client-side fetch lands, and repo.json, the star count. Committed so builds
 * work offline; run it before `bun run build` to refresh (GITHUB_TOKEN optional, raises the
 * rate limit).
 *
 *   bun run scripts/fetch-releases.ts
 */
import { writeFileSync } from "node:fs";
import { join } from "node:path";

import { type GhRelease, RELEASES_URL } from "../src/releases";

const REPO_API = "https://api.github.com/repos/rokartur/BetterCmdTab";
const token = process.env.GITHUB_TOKEN;
const headers = {
  Accept: "application/vnd.github+json",
  ...(token ? { Authorization: `Bearer ${token}` } : {}),
};

async function get<T>(url: string): Promise<T> {
  // A stalled API would hang `docker build`, and the Dockerfile's fallback only runs on exit.
  const res = await fetch(url, { headers, signal: AbortSignal.timeout(10_000) });
  if (!res.ok)
    throw new Error(`fetch-releases: GET ${url} answered ${res.status} ${await res.text()}`);
  return (await res.json()) as T;
}

const releases = await get<GhRelease[]>(RELEASES_URL);
if (releases.length === 0) throw new Error("fetch-releases: no releases returned");
const { stargazers_count: stars } = await get<{ stargazers_count: unknown }>(REPO_API);
if (!Number.isSafeInteger(stars)) throw new Error(`fetch-releases: bad stargazers_count ${stars}`);

// Keep only the fields the page reads — the snapshot ships inside the JS bundle.
const trimmed = releases.map((r) => ({
  tag_name: r.tag_name,
  prerelease: r.prerelease,
  published_at: r.published_at,
  assets: r.assets.map((a) => ({
    name: a.name,
    browser_download_url: a.browser_download_url,
    download_count: a.download_count,
  })),
}));

const root = join(import.meta.dirname, "..");
writeFileSync(join(root, "releases.json"), `${JSON.stringify(trimmed, null, 2)}\n`);
console.log(`fetch-releases: wrote ${trimmed.length} releases (latest ${trimmed[0].tag_name})`);
writeFileSync(join(root, "repo.json"), `${JSON.stringify({ stars }, null, 2)}\n`);
console.log(`fetch-releases: wrote repo.json (${stars} stars)`);
