import { type CSSProperties, useState } from "react";

import { DownloadButton, Icon } from "../StickyCTA";
import { DOCS } from "./Docs";
import { Chord } from "./Keys";

const REPO = "https://github.com/rokartur/BetterCmdTab";

const ExternalLink = "a";

// lg and up only: narrower, it collides with the centered sticky Download pill.
export function BetterAudioCard() {
  const [dismissed, setDismissed] = useState(false);
  if (dismissed) return null;
  return (
    <aside className="enter fixed right-7 bottom-7 z-40 hidden items-center gap-1 rounded-2xl border border-line bg-surface py-2 pr-2 pl-2.5 shadow-[0_6px_24px_rgb(0_0_0/0.08)] [animation-delay:1900ms] lg:flex">
      <ExternalLink
        className="flex items-center gap-2.5 border-0 text-text"
        href="https://betteraudio.pro/"
      >
        <img
          className="block h-8 w-8 shrink-0 rounded-[7px]"
          src="/betteraudio.png"
          alt=""
          width={32}
          height={32}
          decoding="async"
        />
        <span className="flex flex-col">
          <span className="text-[13px] font-semibold">BetterAudio</span>
          <span className="text-[12px] text-dim">Per-app volume for macOS</span>
        </span>
      </ExternalLink>
      <button
        type="button"
        aria-label="Dismiss BetterAudio"
        onClick={() => setDismissed(true)}
        className="cursor-pointer self-start rounded-md border-0 bg-transparent px-1.5 text-[16px] leading-none text-dim hover:text-text"
      >
        &times;
      </button>
    </aside>
  );
}

const footerLinks: Array<[string, string]> = [
  ["Changelog", `${REPO}/releases`],
  ["Documentation", DOCS],
  ["Config reference", `${DOCS}/config-reference/`],
  ["Report an issue", `${REPO}/issues`],
  ["License", `${REPO}/blob/main/LICENSE`],
];

const FOOTER_HEADING = "m-0 mb-5 text-[12px] font-semibold tracking-[0.12em] text-muted uppercase";
const DARK_BUTTON =
  "inline-flex items-center gap-2.5 rounded-xl border border-line bg-surface font-medium text-text transition-colors duration-150 hover:bg-[#1f1e1b]";

export function Footer({ dmgUrl, style }: { dmgUrl: string; style: CSSProperties | undefined }) {
  return (
    <footer
      className="dark bg-[radial-gradient(50%_160px_at_50%_0,rgba(255,255,255,0.05),transparent)]"
      style={style}
    >
      <div className="mx-auto max-w-[1120px] px-6 pt-24">
        <div className="grid grid-cols-[1fr_minmax(0,420px)] gap-16 max-[860px]:grid-cols-1">
          <div className="flex flex-col items-start gap-6">
            <a className="flex items-center gap-3 border-0 text-[17px] font-semibold" href="/">
              <img
                className="block h-9 w-9"
                src="/icon-56.png"
                alt=""
                width={36}
                height={36}
                loading="lazy"
                decoding="async"
              />
              BetterCmdTab
            </a>
            <p className="m-0 text-[clamp(26px,3vw,34px)] leading-[1.1] font-bold tracking-[-0.03em]">
              The ⌘Tab macOS deserves.
            </p>
            <div className="mt-10 flex flex-wrap gap-3 max-[860px]:mt-2">
              <DownloadButton
                href={dmgUrl}
                size="lg"
                className="bg-text text-bg hover:bg-white hover:text-bg"
              />
              <ExternalLink className={`${DARK_BUTTON} h-12 px-5 text-[16px]`} href={REPO}>
                <Icon.GitHub className="h-[18px] w-[18px]" />
                Star on GitHub
              </ExternalLink>
            </div>
          </div>

          <div>
            <h2 className={FOOTER_HEADING}>Resources</h2>
            <ul className="m-0 flex list-none flex-col gap-3 p-0 text-[15px]">
              {footerLinks.map(([label, href]) => (
                <li key={label}>
                  <a className="border-0 text-dim hover:text-text" href={href}>
                    {label}
                  </a>
                </li>
              ))}
            </ul>

            <h2 className={`${FOOTER_HEADING} mt-10 border-t border-line pt-10`}>
              Also by Artur Rok
            </h2>
            <ExternalLink
              className={`${DARK_BUTTON} mb-3 max-w-[360px] gap-3.5 px-4 py-3`}
              href="https://betteraudio.pro/"
            >
              <img
                className="block h-9 w-9 shrink-0 rounded-[8px]"
                src="/betteraudio.png"
                alt=""
                width={36}
                height={36}
                loading="lazy"
                decoding="async"
              />
              <span className="flex flex-col">
                <span className="text-[15px]">BetterAudio</span>
                <span className="text-[13px] font-normal text-dim">
                  Per-app volume and audio routing for macOS
                </span>
              </span>
            </ExternalLink>
            <div className="flex flex-wrap gap-3 text-[14px]">
              <ExternalLink
                className={`${DARK_BUTTON} h-10 px-4`}
                href="https://github.com/rokartur"
              >
                <Icon.GitHub className="h-4 w-4" />
                @rokartur
              </ExternalLink>
            </div>
          </div>
        </div>

        <div className="mt-20 flex flex-wrap justify-between gap-x-6 gap-y-2 border-t border-line pt-7 text-[13px] text-muted">
          <span>© Artur Rok. Open source under GPL v3.</span>
          <span>Not affiliated with Apple Inc.</span>
        </div>

        <div
          aria-hidden="true"
          className="mt-12 h-[0.6em] overflow-hidden [mask-image:linear-gradient(black,transparent_90%)] text-[min(19vw,380px)] opacity-50"
        >
          <Chord className="justify-center" />
        </div>
      </div>
    </footer>
  );
}
