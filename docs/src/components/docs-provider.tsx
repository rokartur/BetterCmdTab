'use client';

import { i18nProvider } from 'fumadocs-ui/i18n';
import { RootProvider } from 'fumadocs-ui/provider/next';
import type { ReactNode } from 'react';

import { defaultLocale, isLocale, type Locale } from '@/lib/i18n';
import { docsBasePath } from '@/lib/shared';
import { uiTranslations } from '@/lib/ui-translations';

export function DocsProvider({ locale, children }: { locale: Locale; children: ReactNode }) {
  function changeLocale(nextLocale: string) {
    if (!isLocale(nextLocale) || nextLocale === locale) return;

    const relativePath = window.location.pathname.startsWith(docsBasePath)
      ? window.location.pathname.slice(docsBasePath.length)
      : window.location.pathname;
    const segments = relativePath.split('/').filter(Boolean);

    if (locale !== defaultLocale && segments[0] === locale) segments.shift();
    if (nextLocale !== defaultLocale) segments.unshift(nextLocale);

    const path = `${docsBasePath}/${segments.join('/')}`;
    window.location.assign(path.endsWith('/') ? path : `${path}/`);
  }

  return (
    <RootProvider
      i18n={{ ...i18nProvider(uiTranslations, locale), onLocaleChange: changeLocale }}
      // Matches the staticGET index in app/api/search — without this the
      // client would query the marketing site's /api/search endpoint.
      search={{ options: { type: 'static', api: `${docsBasePath}/api/search` } }}
    >
      {children}
    </RootProvider>
  );
}
