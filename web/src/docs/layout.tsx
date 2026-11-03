import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared";
import { LanguageSelectText } from "fumadocs-ui/layouts/shared/slots/language-select";
import { Download, Globe } from "lucide-react";

import { messages, type Locale } from "./i18n";
import { SearchableLanguageSelect } from "./LanguageSelect";
import { docsPath, gitConfig } from "./source";

export function baseOptions(locale: Locale): BaseLayoutProps {
  const t = messages[locale].Navigation;
  const releaseUrl = `https://github.com/${gitConfig.user}/${gitConfig.repo}/releases/latest`;

  return {
    nav: {
      url: docsPath([], locale),
      title: (
        <>
          {/* A pre-sized 64px copy (6.5 KB), not the 256px 56 KB master. */}
          <img src="/docs/icon-64.png" alt="" width={22} height={22} className="rounded-[5px]" />
          <span className="font-medium">BetterCmdTab</span>
        </>
      ),
    },
    slots: {
      languageSelect: {
        root: SearchableLanguageSelect,
        text: LanguageSelectText,
      },
    },
    githubUrl: `https://github.com/${gitConfig.user}/${gitConfig.repo}`,
    // `type: 'icon'` items are secondary by default, which is what puts them in
    // the sidebar footer pill alongside the icon `githubUrl` generates.
    links: [
      {
        type: "custom",
        on: "nav",
        children: (
          // The guide pages' black pill, without their Motion hover so docs skip ~800 KB of JS.
          <a
            href={releaseUrl}
            aria-label={t.downloadReleaseLabel}
            className="bg-fd-foreground text-fd-background inline-flex h-9 items-center gap-1.5 rounded-full px-4 text-[13.5px] font-semibold transition-opacity hover:opacity-85"
          >
            <Download className="size-4" />
            {t.download}
          </a>
        ),
      },
      {
        type: "icon",
        on: "menu",
        label: t.downloadReleaseLabel,
        text: t.download,
        icon: <Download />,
        url: releaseUrl,
        external: true,
      },
      {
        type: "icon",
        label: t.websiteLabel,
        text: t.website,
        icon: <Globe />,
        // A full load: the marketing pages use a different stylesheet.
        url: "/",
        external: true,
      },
    ],
  };
}
