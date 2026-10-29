import { Tab, Tabs } from "fumadocs-ui/components/tabs";
import defaultMdxComponents from "fumadocs-ui/mdx";
import type { MDXComponents } from "mdx/types";

import { ConfigObject, ConfigReference } from "./ConfigReference";
import type { Locale } from "./i18n";

export function getMDXComponents(locale: Locale) {
  return {
    ...defaultMdxComponents,
    Tabs,
    Tab,
    ConfigReference: () => <ConfigReference locale={locale} />,
    ConfigObject: ({ name }: { name: string }) => <ConfigObject name={name} locale={locale} />,
  } satisfies MDXComponents;
}
