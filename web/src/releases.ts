/**
 * Release channels for the download button, plus the client-side cache that
 * keeps us off GitHub's API most of the time.
 *
 * Pure logic, deliberately free of React and of any import that pulls it in, so
 * releases.test.ts can exercise it under `bun test`.
 */

const REPO = "https://github.com/rokartur/BetterCmdTab";

// One call to the list endpoint covers the latest stable release (the default
// download), the newest prerelease (the opt-in beta channel), and the
// cumulative download count across every release — so it stays one request.
// Splitting it would halve the bytes but double what we spend of the per-IP
// rate limit, and the limit is the binding constraint, not the bytes.
export const RELEASES_URL =
  "https://api.github.com/repos/rokartur/BetterCmdTab/releases?per_page=100";

export const FETCH_TIMEOUT = 8000;

export interface GhAsset {
  name: string;
  browser_download_url: string;
  download_count: number;
}

export interface GhRelease {
  tag_name: string;
  prerelease: boolean;
  published_at: string | null;
  assets: GhAsset[];
}

export interface Channel {
  version: string | null;
  // ISO timestamp of the release, shown as "Updated <month>".
  published: string | null;
  dmgUrl: string;
}

export interface Releases {
  // Latest stable download (the default).
  stable: Channel;
  // Latest prerelease, only present when it is newer than `stable` — otherwise
  // null and the beta toggle stays hidden.
  beta: Channel | null;
  totalDownloads: number;
}

const dmgOf = (r: GhRelease | undefined): Channel => ({
  version: r?.tag_name ?? null,
  published: r?.published_at ?? null,
  dmgUrl:
    r?.assets.find((a) => a.name.endsWith(".dmg"))?.browser_download_url ??
    `${REPO}/releases/latest`,
});

// Releases come newest-first. A beta is only worth offering when the very
// newest release is a prerelease (i.e. ahead of stable); once stable catches
// up, releases[0] is stable and the toggle disappears.
export function channels(releases: GhRelease[]): Releases {
  return {
    stable: dmgOf(releases.find((r) => !r.prerelease) ?? releases[0]),
    beta: releases[0]?.prerelease ? dmgOf(releases[0]) : null,
    // Every asset, including the updater's manifest and .sig fetches.
    totalDownloads: releases.reduce(
      (sum, r) => sum + r.assets.reduce((s, a) => s + a.download_count, 0),
      0,
    ),
  };
}

export const CACHE_KEY = "BetterCmdTab.releases";

// GitHub's anonymous API allows 60 requests/hour per IP — shared by everyone
// behind that IP — and is regularly sitting at zero, so a 403 is the common
// case rather than the exception. Inside this window a visitor costs no request
// and no ~180 KB response at all.
export const CACHE_TTL = 6 * 60 * 60 * 1000;

export interface CacheEntry {
  at: number;
  rel: Releases;
}

function isChannel(c: unknown): c is Channel {
  if (typeof c !== "object" || c === null) return false;
  const { version, published, dmgUrl } = c as Channel;
  if (version !== null && typeof version !== "string") return false;
  // Also rejects entries cached before releases carried a date, so they refetch.
  // An unparseable date would make Intl.DateTimeFormat throw during render.
  if (published !== null && (typeof published !== "string" || Number.isNaN(Date.parse(published))))
    return false;
  // dmgUrl goes straight into an <a href download>. Only ever accept one
  // pointing back at this repo, so a corrupted or tampered-with entry cannot
  // turn the download button into a redirect to someone else's binary.
  return typeof dmgUrl === "string" && dmgUrl.startsWith(`${REPO}/`);
}

export function readCache(now: number = Date.now()): CacheEntry | null {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (raw === null) return null;
    const entry = JSON.parse(raw) as CacheEntry;
    // A stamp from the future — clock skew, or a hand-edited value — would
    // never expire and would pin this visitor to the entry forever.
    if (!Number.isFinite(entry?.at) || entry.at > now) return null;
    const rel = entry.rel;
    if (typeof rel !== "object" || rel === null) return null;
    if (!Number.isSafeInteger(rel.totalDownloads) || rel.totalDownloads < 0) return null;
    if (!isChannel(rel.stable)) return null;
    if (rel.beta !== null && !isChannel(rel.beta)) return null;
    return entry;
  } catch {
    return null;
  }
}

export function writeCache(rel: Releases, now: number = Date.now()) {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify({ at: now, rel }));
  } catch {
    // Private mode or a full quota — we simply refetch next time.
  }
}

export const isFresh = (entry: CacheEntry, now: number = Date.now()) => now - entry.at < CACHE_TTL;

// The download total only ever grows, so it doubles as a clock: whichever of
// the two was taken later reports more downloads. That is what stops a cache
// hit from showing an *older* version than the visitor already saw, back when
// the build-time snapshot was the newer of the two — without having to bake a
// timestamp into releases.json and keep the two in sync.
export function freshest(baked: Releases, cached: Releases | null | undefined): Releases {
  if (!cached) return baked;
  return cached.totalDownloads > baked.totalDownloads ? cached : baked;
}
