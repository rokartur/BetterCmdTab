import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';
import { LanguageSelectText } from 'fumadocs-ui/layouts/shared/slots/language-select';
import { Download, Globe } from 'lucide-react';
import { getTranslations } from 'next-intl/server';

import { SearchableLanguageSelect } from '@/components/language-select';
import { defaultLocale, type Locale } from '@/lib/i18n';

import { appName, gitConfig, homeUrl, docsBasePath } from './shared';

export async function baseOptions(locale: Locale): Promise<BaseLayoutProps> {
  const t = await getTranslations({ locale, namespace: 'Navigation' });

  return {
    nav: {
      url: locale === defaultLocale ? '/' : `/${locale}/`,
      title: (
        <>
          {/* A pre-sized 64px copy (6.5 KB), not the 256px 56 KB master: a
              static export has no image optimizer, so whatever is referenced
              here is what every visitor downloads. next/image would only add
              markup, not resizing. */}
          {/* eslint-disable-next-line next/no-img-element */}
          <img
            src={`${docsBasePath}/icon-64.png`}
            alt=""
            width={22}
            height={22}
            className="rounded-[5px]"
          />
          <span className="font-medium">{appName}</span>
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
        type: 'icon',
        label: t('downloadReleaseLabel'),
        text: t('download'),
        icon: <Download />,
        url: `https://github.com/${gitConfig.user}/${gitConfig.repo}/releases/latest`,
        external: true,
      },
      {
        type: 'icon',
        label: t('websiteLabel'),
        text: t('website'),
        icon: <Globe />,
        // Absolute + external on purpose: the marketing site is a different app
        // on the same host, so client-side routing must not try to handle it.
        url: homeUrl,
        external: true,
      },
    ],
  };
}
