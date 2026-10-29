import { defineI18n } from "fumadocs-core/i18n";

import english from "./messages.en.json";
import polish from "./messages.pl.json";

export const defaultLocale = "en";

export const i18n = defineI18n({
  defaultLanguage: defaultLocale,
  languages: [defaultLocale, "pl"],
  hideLocale: "default-locale",
  parser: "dir",
  fallbackLanguage: null,
});

export type Locale = (typeof i18n.languages)[number];

export function isLocale(value: string | undefined): value is Locale {
  return value !== undefined && i18n.languages.some((locale) => locale === value);
}

/** Split a catch-all route's splat (`pl/overrides/`) into its locale and content slugs. */
export function resolveLocalePath(splat: string | undefined): { locale: Locale; slugs: string[] } {
  const path = splat?.split("/").filter(Boolean) ?? [];
  const [candidate, ...rest] = path;
  if (candidate !== defaultLocale && isLocale(candidate)) return { locale: candidate, slugs: rest };

  return { locale: defaultLocale, slugs: path };
}

export function localizedSegments(locale: string | undefined, segments: string[]): string[] {
  return locale && locale !== defaultLocale ? [locale, ...segments] : segments;
}

export const messages = { en: english, pl: polish } satisfies Record<Locale, typeof english>;
