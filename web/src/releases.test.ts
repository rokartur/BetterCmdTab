// TypeScript 6 no longer auto-includes @types/bun, and without this `bun:test`
// resolves under `bun test` but not under `tsc --noEmit`.
/// <reference types="bun" />
import { beforeEach, expect, test } from "bun:test";

import {
  CACHE_KEY,
  CACHE_TTL,
  channels,
  freshest,
  type GhRelease,
  isFresh,
  readCache,
  type Releases,
  writeCache,
} from "./releases";

const REPO = "https://github.com/rokartur/BetterCmdTab";

let store: Record<string, string> = {};
// Bun has no DOM; the module only ever touches these two methods.
globalThis.localStorage = {
  getItem: (k: string) => (k in store ? store[k] : null),
  setItem: (k: string, v: string) => {
    store[k] = v;
  },
} as Storage;

beforeEach(() => {
  store = {};
});

const release = (tag: string, prerelease: boolean, downloads: number): GhRelease => ({
  tag_name: tag,
  prerelease,
  published_at: "2026-07-03T12:30:53Z",
  assets: [
    {
      name: `BetterCmdTab-${tag}.dmg`,
      browser_download_url: `${REPO}/releases/download/${tag}/BetterCmdTab.dmg`,
      download_count: downloads,
    },
  ],
});

test("channels picks the newest stable and exposes a beta only when it leads", () => {
  const beta = { ...release("26.7-beta.3", true, 10), published_at: "2026-07-09T08:00:00Z" };
  const withBeta = channels([beta, release("26.6.1", false, 90)]);
  expect(withBeta.stable.version).toBe("26.6.1");
  expect(withBeta.stable.published).toBe("2026-07-03T12:30:53Z");
  expect(withBeta.beta?.version).toBe("26.7-beta.3");
  expect(withBeta.beta?.published).toBe("2026-07-09T08:00:00Z");
  expect(withBeta.totalDownloads).toBe(100);

  // Once stable catches up the toggle disappears.
  const settled = channels([release("26.7", false, 5), release("26.7-beta.3", true, 10)]);
  expect(settled.stable.version).toBe("26.7");
  expect(settled.beta).toBeNull();
});

test("the download total counts builds, not updater manifest checks", () => {
  const r = release("26.7", false, 12);
  const asset = (name: string, download_count: number) => ({
    name,
    browser_download_url: `${REPO}/releases/download/26.7/${name}`,
    download_count,
  });
  r.assets.push(
    asset("BetterCmdTab-26.7.zip", 3),
    asset("betterupdater-manifest.json", 500),
    asset("betterupdater-manifest.json.sig", 500),
  );
  expect(channels([r]).totalDownloads).toBe(15);
});

test("channels survives an empty list and a release with no .dmg", () => {
  const empty = channels([]);
  expect(empty.stable.version).toBeNull();
  expect(empty.stable.dmgUrl).toBe(`${REPO}/releases/latest`);
  expect(empty.beta).toBeNull();
  expect(empty.totalDownloads).toBe(0);

  const noDmg = channels([{ tag_name: "26.7", prerelease: false, published_at: null, assets: [] }]);
  expect(noDmg.stable.dmgUrl).toBe(`${REPO}/releases/latest`);
});

test("a written cache round-trips and expires on the TTL boundary", () => {
  const rel = channels([release("26.7", false, 12)]);
  const at = 1_000_000;
  writeCache(rel, at);

  const entry = readCache(at)!;
  expect(entry.rel).toEqual(rel);
  expect(isFresh(entry, at + CACHE_TTL - 1)).toBe(true);
  expect(isFresh(entry, at + CACHE_TTL)).toBe(false);
});

test("a stamp from the future is rejected instead of never expiring", () => {
  writeCache(channels([release("26.7", false, 12)]), 5000);
  expect(readCache(4999)).toBeNull();
  expect(readCache(5000)).not.toBeNull();
});

test("corrupt, legacy and tampered entries are rejected, never rendered", () => {
  const ok = channels([release("26.7", false, 12)]);
  const bad = [
    "not json",
    "14072", // the legacy bare-number value this key used to hold
    "null",
    "[]",
    JSON.stringify({ at: "x", rel: ok }),
    JSON.stringify({ at: 1 }),
    JSON.stringify({ at: 1, rel: { ...ok, totalDownloads: -1 } }),
    JSON.stringify({ at: 1, rel: { ...ok, totalDownloads: 1.5 } }),
    JSON.stringify({ at: 1, rel: { ...ok, stable: { ...ok.stable, dmgUrl: 42 } } }),
    // Cached before channels carried a release date.
    JSON.stringify({
      at: 1,
      rel: { ...ok, stable: { version: "26.7", dmgUrl: ok.stable.dmgUrl } },
    }),
    JSON.stringify({ at: 1, rel: { ...ok, stable: { ...ok.stable, published: "soon" } } }),
    // An href pointing anywhere but this repo must never reach the page.
    JSON.stringify({
      at: 1,
      rel: { ...ok, stable: { ...ok.stable, dmgUrl: "javascript:alert(1)" } },
    }),
    JSON.stringify({
      at: 1,
      rel: { ...ok, stable: { ...ok.stable, dmgUrl: "https://evil.example/x.dmg" } },
    }),
    JSON.stringify({ at: 1, rel: { ...ok, beta: { ...ok.stable, dmgUrl: "https://evil.test" } } }),
  ];
  for (const raw of bad) {
    store[CACHE_KEY] = raw;
    expect(readCache(10_000)).toBeNull();
  }
});

test("freshest never lets the shown version go backwards", () => {
  const older: Releases = channels([release("26.6.1", false, 100)]);
  const newer: Releases = channels([release("26.7", false, 150)]);

  // Cache fetched after the deploy wins outright — version included.
  expect(freshest(older, newer).stable.version).toBe("26.7");
  // A redeploy that overtook the cache wins instead, so we never regress.
  expect(freshest(newer, older).stable.version).toBe("26.7");
  // Equal counts mean the same era; prefer the build-time snapshot.
  expect(freshest(older, channels([release("26.6.1", false, 100)])).stable.version).toBe("26.6.1");
  expect(freshest(older, null)).toBe(older);
});

test("a throwing localStorage degrades to the snapshot instead of crashing", () => {
  const broken = {
    getItem: () => {
      throw new Error("SecurityError");
    },
    setItem: () => {
      throw new Error("QuotaExceededError");
    },
  } as unknown as Storage;
  const real = globalThis.localStorage;
  globalThis.localStorage = broken;
  try {
    expect(readCache()).toBeNull();
    expect(() => writeCache(channels([release("26.7", false, 1)]))).not.toThrow();
  } finally {
    globalThis.localStorage = real;
  }
});
