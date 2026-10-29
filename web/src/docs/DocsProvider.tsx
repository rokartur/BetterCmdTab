import { i18nProvider } from "fumadocs-ui/i18n";
import { RootProvider } from "fumadocs-ui/provider/tanstack";
import type { ReactNode } from "react";

import type { Locale } from "./i18n";
import { docsPath } from "./source";
import { uiTranslations } from "./ui-translations";

export function DocsProvider({
  locale,
  slugs,
  children,
}: {
  locale: Locale;
  slugs: string[];
  children: ReactNode;
}) {
  // A full load, so the prerendered page brings its own <html lang>.
  function changeLocale(nextLocale: string) {
    if (nextLocale !== locale) window.location.assign(docsPath(slugs, nextLocale));
  }

  return (
    <RootProvider
      i18n={{ ...i18nProvider(uiTranslations, locale), onLocaleChange: changeLocale }}
      // The staticGET index prerendered by routes/docs/api/search.ts.
      search={{ options: { type: "static", api: "/docs/api/search" } }}
    >
      {children}
    </RootProvider>
  );
}
