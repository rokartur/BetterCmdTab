import { LiveConfig } from "./LiveConfig";
import { H2 } from "./tokens";

// Same origin, served by the docs app rather than this static export — plain
// anchors so the browser does a real navigation instead of the router
// swallowing it.
export const DOCS = "/docs";

// Paths are relative to DOCS; the quick start is the docs landing page, served
// as bare /docs by a Cloudflare rewrite. The rest end in a slash to match the
// docs' canonical URLs
// — the bare form is a 301 on both deploy targets, and an internal link should
// not spend a redirect.
const docsLinks: Array<[string, string, string]> = [
  ["Quick start", "Install, permissions, your first switch", ""],
  ["Config file", "How the live two-way sync works", "/configuration/"],
  ["Config reference", "Every key, with types and defaults", "/config-reference/"],
  ["Per-shortcut overrides", "A different switcher on every hotkey", "/overrides/"],
];

export function Docs() {
  return (
    <section
      id="config"
      className="dark -mx-6 rounded-[28px] px-14 py-16 max-[860px]:rounded-none max-[860px]:px-6 max-[860px]:py-14"
    >
      <h2 className={H2}>Configure it in a file.</h2>
      <p className="m-0 -mt-3 mb-11 max-w-[54ch] text-[17px] text-muted">
        Every setting lives in a plain JSON file you can diff, version and keep in your dotfiles.
        Save it and the switcher changes, no restart. Change a setting in the app and the file is
        written back.
      </p>

      <LiveConfig />

      <nav
        aria-label="Configuration docs"
        className="mt-11 grid grid-cols-4 border-t border-line max-[860px]:grid-cols-2 max-[860px]:gap-y-4"
      >
        {docsLinks.map(([title, desc, path], i) => (
          <div
            key={title}
            className={
              i > 0 ? "border-l border-line pl-5 max-[860px]:border-l-0 max-[860px]:pl-0" : ""
            }
          >
            <a className="group/doc block border-0 pt-[18px] pr-5" href={`${DOCS}${path}`}>
              <span className="block font-medium text-text transition-colors duration-150 group-hover/doc:text-accent">
                {title}
                <span
                  aria-hidden
                  className="ml-1.5 inline-block text-muted transition-transform duration-200 group-hover/doc:translate-x-1 motion-reduce:transition-none"
                >
                  →
                </span>
              </span>
              <span className="mt-0.5 block text-[13px] text-muted">{desc}</span>
            </a>
          </div>
        ))}
      </nav>
    </section>
  );
}
