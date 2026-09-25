import { join, sep } from "node:path";

// Same contract as GitHub Pages: `<dir>/index.html` for a slashed URL, a bare dir 301s to the
// slashed one, /404.html for anything missing. Bare `/docs` is the canonical docs home, served as is.
const root = join(import.meta.dir, "out");
const notFound = () => new Response(Bun.file(join(root, "404.html")), { status: 404 });

Bun.serve({
  port: Number(process.env.PORT ?? 3000),
  async fetch(req) {
    const { pathname } = new URL(req.url);
    const path = join(root, decodeURIComponent(pathname));
    if (path !== root && !path.startsWith(root + sep)) return notFound();

    const file = Bun.file(
      pathname.endsWith("/") || pathname === "/docs" ? join(path, "index.html") : path,
    );
    if (!(await file.exists())) {
      if (!(await Bun.file(join(path, "index.html")).exists())) return notFound();
      return new Response(null, { status: 301, headers: { Location: `${pathname}/` } });
    }

    // Vite (/assets/) and Next (/docs/_next/static/) content-hash these, so a change gets a new URL.
    const immutable = pathname.startsWith("/assets/") || pathname.startsWith("/docs/_next/static/");
    return new Response(file, {
      headers: immutable ? { "Cache-Control": "public, max-age=31536000, immutable" } : {},
    });
  },
});
