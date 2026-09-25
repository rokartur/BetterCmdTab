import { DocsLayout } from 'fumadocs-ui/layouts/docs';
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import type { ReactNode } from 'react';

import { DocsProvider } from '@/components/docs-provider';
import { resolveLocalePath } from '@/lib/i18n';
import { baseOptions } from '@/lib/layout.shared';
import { appName, docsBasePath, siteUrl } from '@/lib/shared';
import { source } from '@/lib/source';

import '../../global.css';

type Props = {
  children: ReactNode;
  params: Promise<{ slug?: string[] }>;
};

export async function generateMetadata(props: Props): Promise<Metadata> {
  const { locale } = resolveLocalePath((await props.params).slug);
  const t = await getTranslations({ locale, namespace: 'Metadata' });

  return {
    metadataBase: new URL(siteUrl),
    title: {
      default: t('defaultTitle'),
      template: `%s — ${appName}`,
    },
    description: t('description'),
    applicationName: appName,
    icons: {
      // Literal hrefs are not prefixed by Next's basePath.
      icon: [
        { url: `${docsBasePath}/favicon-16.png`, sizes: '16x16', type: 'image/png' },
        { url: `${docsBasePath}/favicon-32.png`, sizes: '32x32', type: 'image/png' },
        { url: `${docsBasePath}/icon.png`, sizes: '256x256', type: 'image/png' },
      ],
      apple: `${docsBasePath}/apple-touch-icon.png`,
    },
    openGraph: {
      type: 'website',
      siteName: t('siteName'),
    },
  };
}

export default async function Layout(props: Props) {
  const { locale } = resolveLocalePath((await props.params).slug);

  return (
    // The root layout lives inside the optional catch-all so the static Polish
    // pages can set the document language without middleware or a duplicate tree.
    <html lang={locale} suppressHydrationWarning>
      <body className="flex min-h-screen flex-col">
        <DocsProvider locale={locale}>
          <DocsLayout tree={source.getPageTree(locale)} {...await baseOptions(locale)}>
            {props.children}
          </DocsLayout>
        </DocsProvider>
      </body>
    </html>
  );
}
