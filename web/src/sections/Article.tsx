import type { ReactNode } from "react";

import { SITE } from "../routes/__root";
import { DownloadButton } from "../StickyCTA";
import { BREW, useReleases } from "./Download";
import { Footer } from "./Footer";

// Head tags for a guide page; each spells out its own canonical, see routes/index.tsx.
export function articleHead({
  path,
  title,
  description,
}: {
  path: string;
  title: string;
  description: string;
}) {
  const url = `${SITE}${path}`;
  return {
    meta: [
      { title },
      { name: "description", content: description },
      { property: "og:type", content: "article" },
      { property: "og:title", content: title },
      { property: "og:description", content: description },
      { property: "og:url", content: url },
      { name: "twitter:title", content: title },
      { name: "twitter:description", content: description },
    ],
    links: [{ rel: "canonical", href: url }],
  };
}

// Plain prose for the guide pages: the elements are styled from here, so the pages stay markup.
const PROSE =
  "[&_a]:text-accent [&_a]:underline [&_a]:underline-offset-2 [&_code]:rounded [&_code]:bg-black/5 [&_code]:px-1 [&_code]:font-mono [&_code]:text-[0.92em] [&_h2]:mt-14 [&_h2]:mb-4 [&_h2]:text-[clamp(24px,3vw,30px)] [&_h2]:leading-[1.15] [&_h2]:font-bold [&_h2]:tracking-[-0.025em] [&_h2]:text-text [&_li]:my-1.5 [&_ol]:list-decimal [&_ol]:pl-6 [&_p]:my-4 [&_table]:my-6 [&_table]:w-full [&_table]:border-collapse [&_td]:border-b [&_td]:border-line [&_td]:py-2.5 [&_td]:pr-4 [&_td]:align-top [&_th]:border-b [&_th]:border-line [&_th]:py-2.5 [&_th]:pr-4 [&_th]:text-left [&_th]:font-semibold [&_th]:text-text [&_ul]:list-disc [&_ul]:pl-6";

export function Article({
  title,
  lead,
  children,
}: {
  title: string;
  lead: string;
  children: ReactNode;
}) {
  const { stable } = useReleases();
  return (
    <>
      <main className="mx-auto max-w-[760px] px-6 pt-10 pb-28">
        <nav className="flex items-center justify-between gap-4">
          <a className="flex items-center gap-2.5 border-0 font-semibold text-text" href="/">
            <img src="/icon-56.png" alt="" width={28} height={28} className="block h-7 w-7" />
            BetterCmdTab
          </a>
          <DownloadButton
            href={stable.dmgUrl}
            size="sm"
            className="bg-text text-bg hover:bg-[#3a3833]"
          />
        </nav>
        <article className={`mt-16 text-[17px] leading-[1.6] text-dim ${PROSE}`}>
          <h1 className="m-0 text-[clamp(34px,5vw,52px)] leading-[1.05] font-bold tracking-[-0.035em] text-balance text-text">
            {title}
          </h1>
          <p className="mt-5 text-[19px] text-muted">{lead}</p>
          {children}
        </article>
        <p className="mt-14 mb-0 flex flex-wrap items-center gap-x-5 gap-y-3">
          <DownloadButton
            href={stable.dmgUrl}
            size="lg"
            className="bg-text text-bg hover:bg-[#3a3833]"
          />
          <span className="text-[15px] text-muted">
            or <code className="font-mono">{BREW}</code>
          </span>
        </p>
      </main>
      <Footer dmgUrl={stable.dmgUrl} style={undefined} />
    </>
  );
}
