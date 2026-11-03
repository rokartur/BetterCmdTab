import { join, sep } from "node:path";

// `<dir>/index.html` for a bare URL, a slashed one 301s to the bare form, /404.html for
// anything missing.
const root = join(import.meta.dir, "out");
const notFound = () => new Response(Bun.file(join(root, "404.html")), { status: 404 });
const redirect = (location: string) =>
  new Response(null, { status: 301, headers: { Location: location } });
const cached = (file: Blob, cacheControl: string) =>
  new Response(file, { headers: { "Cache-Control": cacheControl } });

Bun.serve({
  port: Number(process.env.PORT ?? 3000),
  // Bun's development error page leaks the stack and cwd; the image never sets NODE_ENV.
  development: false,
  async fetch(req) {
    const { pathname, search } = new URL(req.url);
    // "//evil.com/..%2fdocs" joins to out/docs, and the trailing-slash 301 would echo it as an off-site Location.
    if (pathname.startsWith("//")) return notFound();
    // The Polish docs once lived at /pl/; Google still crawls those URLs.
    if (pathname === "/pl" || pathname.startsWith("/pl/"))
      return redirect(`/docs${pathname.replace(/\/$/, "")}${search}`);
    if (pathname !== "/" && pathname.endsWith("/"))
      return redirect(`${pathname.slice(0, -1)}${search}`);

    let path: string;
    try {
      path = join(root, decodeURIComponent(pathname));
    } catch {
      // A malformed escape such as /%ff throws URIError.
      return notFound();
    }
    if (path !== root && !path.startsWith(root + sep)) return notFound();

    let file = Bun.file(path);
    if (!(await file.exists())) file = Bun.file(join(path, "index.html"));
    if (!(await file.exists())) return notFound();

    // Vite content-hashes these, so a change gets a new URL.
    if (pathname.startsWith("/assets/")) return cached(file, "public, max-age=31536000, immutable");
    // Not hashed, but replaced rarely: a week of staleness after a redesign is the trade. The docs
    // og images are regenerated under the same URL on every build, so they stay uncached.
    if (/\.(png|jpe?g|webp|wav)$/.test(pathname) && !pathname.startsWith("/docs/og/"))
      return cached(file, "public, max-age=604800");
    // A heuristically cached page would request hashed chunks a later deploy deleted.
    if (file.type.startsWith("text/html")) return cached(file, "no-cache");
    return new Response(file);
  },
});
