import type { TOCItemType } from 'fumadocs-core/toc';
import { getTranslations } from 'next-intl/server';

import schema from '@/data/config-schema.json';
import type { Locale } from '@/lib/i18n';

/**
 * The reference tables are built from `src/data/config-schema.json` — a verbatim
 * copy of the `schema.json` BetterCmdTab writes next to `config.json`. Types,
 * descriptions, allowed values and ranges therefore come from the app itself and
 * cannot drift from what it accepts.
 *
 * Refresh it with:
 *   cp ~/.config/bettercmdtab/schema.json docs/src/data/config-schema.json
 *
 * Only two things live here rather than in the schema: the section a key belongs
 * to and its default value, neither of which the app emits. A key missing from
 * both maps still renders — it lands in "Other" with an unknown default, so a
 * newly added preference is visibly unsorted instead of silently dropped.
 */

export type SchemaFragment = {
  type?: string;
  description?: string;
  enum?: string[];
  enumDescriptions?: string[];
  minimum?: number;
  maximum?: number;
  minItems?: number;
  maxItems?: number;
  pattern?: string;
  items?: SchemaFragment & {
    properties?: Record<string, SchemaFragment>;
    required?: string[];
    additionalProperties?: boolean;
  };
};

const properties = schema.properties as Record<string, SchemaFragment>;

/** Ordered sections, mirroring how the settings window groups the same options. */
const sections: { title: string; keys: string[] }[] = [
  {
    title: 'Display & timing',
    keys: ['displayMode', 'revealDelayMs', 'titleRefreshIntervalMs'],
  },
  {
    title: 'Layout',
    keys: [
      'layoutMode',
      'panelScalePercent',
      'listWidthPercent',
      'gridMaxColumns',
      'gridSingleRow',
    ],
  },
  {
    title: 'Appearance',
    keys: [
      'panelAppearance',
      'panelOpacity',
      'panelCornerRadius',
      'backdropMaterial',
      'animationsEnabled',
      'fontScale',
      'fontFace',
      'boldSelectedLabel',
      'showApplicationNames',
      'showWindowStatusIcons',
      'showWindowTitleLabel',
      'previewTitleAlignment',
      'titleTruncationMode',
      'browserTabPreviews',
      'livePreviews',
    ],
  },
  {
    title: 'Contents',
    keys: [
      'sortOrder',
      'spaceScope',
      'instantSpaceSwitch',
      'applicationsOnly',
      'windowDrillEnabled',
      'showMinimizedWindows',
      'showHiddenApps',
      'sinkHiddenApps',
      'sinkMinimizedWindows',
      'showWindowlessApps',
      'showUnreadBadges',
      'showRecentlyClosed',
      'recentlyClosedLimit',
      'pinnedBundleIDs',
      'hideAllExcludedBundleIDs',
    ],
  },
  {
    title: 'Tabs',
    keys: [
      'tabDrillEnabled',
      'expandTabsAsWindows',
      'expandBrowserTabsAsWindows',
      'browserTabRowLimit',
      'showBrowserIconOnTabs',
      'browserTabMRU',
    ],
  },
  {
    title: 'Search',
    keys: [
      'fuzzySearchEnabled',
      'fuzzySearchRankBestMatchFirst',
      'searchIncludesLaunchableApps',
      'searchExpandsBrowserTabs',
      'searchDismissMode',
      'letterHintsEnabled',
      'quickJumpMappings',
      'letterHintExcludedBundleIDs',
      'letterChainTimeoutMs',
    ],
  },
  {
    title: 'Keyboard',
    keys: [
      'stayOpenOnRelease',
      'stayOpenOnQuickTap',
      'shiftTapStepsBackward',
      'backtickReversesAppSwitching',
      'vimNavigationEnabled',
    ],
  },
  {
    title: 'Mouse & hover',
    keys: [
      'scrollToSwitch',
      'scrollReverseDirection',
      'clickOutsideToDismiss',
      'mouseHoverSelectionEnabled',
      'mouseClickSelectionEnabled',
      'hoverActionsEnabled',
      'hoverShowClose',
      'hoverShowMinimize',
      'hoverShowMaximize',
      'hoverShowHide',
      'hoverShowQuit',
      'hoverShowForceQuit',
    ],
  },
  {
    title: 'Window management',
    keys: ['cycleTileWidths'],
  },
  {
    title: 'Shortcuts',
    keys: ['directActivationBindings', 'nextScopedShortcutID'],
  },
  {
    title: 'Feedback & menu bar',
    keys: [
      'hideMenuBarIcon',
      'hapticOnCommit',
      'soundOnCommit',
      'commitSoundName',
      'hideFromScreenSharing',
    ],
  },
  {
    title: 'Trackpad swipe',
    keys: [
      'experimentalSwipeTrigger',
      'swipeMode',
      'swipeReverseDirection',
      'swipeCommitOnRelease',
      'swipeSensitivity',
    ],
  },
  {
    title: 'Legacy',
    keys: [
      'panelSize',
      'currentSpaceOnly',
      'excludedBundleIDs',
      'experimentalUnreadBadges',
      'experimentalBrowserTabMRU',
      'experimentalInstantSpaceSwitch',
      'experimentalBrowserTabPreviews',
      'experimentalLivePreviews',
      'scopedShortcutScopes',
    ],
  },
];

const sectionTranslationKeys: Record<string, string> = {
  'Display & timing': 'displayTiming',
  Layout: 'layout',
  Appearance: 'appearance',
  Contents: 'contents',
  Tabs: 'tabs',
  Search: 'search',
  Keyboard: 'keyboard',
  'Mouse & hover': 'mouseHover',
  'Window management': 'windowManagement',
  Shortcuts: 'shortcuts',
  'Feedback & menu bar': 'feedbackMenuBar',
  'Trackpad swipe': 'trackpadSwipe',
  Legacy: 'legacy',
};

/**
 * Defaults as applied by `Preferences.reloadFromDefaults()` when the key is
 * absent. Rendered verbatim, so enums use their raw JSON value rather than the
 * Swift case name.
 */
const defaults: Record<string, string> = {
  animationsEnabled: 'true',
  applicationsOnly: 'false',
  backdropMaterial: '"hud"',
  backtickReversesAppSwitching: 'false',
  boldSelectedLabel: 'true',
  browserTabMRU: 'false',
  browserTabPreviews: 'false',
  browserTabRowLimit: '0',
  clickOutsideToDismiss: 'true',
  commitSoundName: '"Tink"',
  cycleTileWidths: 'false',
  directActivationBindings: '["", "", "", "", "", "", "", "", ""]',
  displayMode: '"mouseCursor"',
  expandBrowserTabsAsWindows: 'false',
  expandTabsAsWindows: 'false',
  experimentalSwipeTrigger: 'false',
  fontFace: '"system"',
  fontScale: '"standard"',
  fuzzySearchEnabled: 'true',
  fuzzySearchRankBestMatchFirst: 'false',
  gridMaxColumns: '0',
  gridSingleRow: 'true',
  hapticOnCommit: 'false',
  hideAllExcludedBundleIDs: '[]',
  hideFromScreenSharing: 'false',
  hideMenuBarIcon: 'false',
  hoverActionsEnabled: 'false',
  hoverShowClose: 'true',
  hoverShowForceQuit: 'false',
  hoverShowHide: 'true',
  hoverShowMaximize: 'true',
  hoverShowMinimize: 'true',
  hoverShowQuit: 'true',
  instantSpaceSwitch: 'false',
  layoutMode: '"iconDock"',
  letterChainTimeoutMs: '1000',
  letterHintExcludedBundleIDs: '[]',
  letterHintsEnabled: 'true',
  listWidthPercent: '100',
  livePreviews: 'false',
  mouseClickSelectionEnabled: 'true',
  mouseHoverSelectionEnabled: 'true',
  panelAppearance: '"system"',
  panelCornerRadius: '0',
  panelOpacity: '100',
  panelScalePercent: '100',
  pinnedBundleIDs: '[]',
  previewTitleAlignment: '"center"',
  quickJumpMappings: '[]',
  recentlyClosedLimit: '5',
  revealDelayMs: '100',
  scrollReverseDirection: 'false',
  scrollToSwitch: 'true',
  searchDismissMode: '"holdModifier"',
  searchExpandsBrowserTabs: 'false',
  searchIncludesLaunchableApps: 'true',
  shiftTapStepsBackward: 'true',
  showApplicationNames: 'true',
  showBrowserIconOnTabs: 'false',
  showHiddenApps: 'true',
  showMinimizedWindows: 'true',
  showRecentlyClosed: 'false',
  showUnreadBadges: 'true',
  showWindowStatusIcons: 'true',
  showWindowTitleLabel: 'true',
  showWindowlessApps: 'true',
  sinkHiddenApps: 'true',
  sinkMinimizedWindows: 'true',
  sortOrder: '"mru"',
  soundOnCommit: 'false',
  spaceScope: '"allSpaces"',
  stayOpenOnQuickTap: 'false',
  stayOpenOnRelease: 'false',
  swipeCommitOnRelease: 'false',
  swipeMode: '"openSwitcher"',
  swipeReverseDirection: 'false',
  swipeSensitivity: '5',
  tabDrillEnabled: 'true',
  titleRefreshIntervalMs: '200',
  titleTruncationMode: '"tail"',
  vimNavigationEnabled: 'false',
  windowDrillEnabled: 'true',
};

export type ConfigKey = {
  name: string;
  fragment: SchemaFragment;
  default: string | null;
};

export type ConfigSection = {
  title: string;
  translationKey: string;
  keys: ConfigKey[];
};

/** Keys documented on their own page instead of in a section table. */
export const objectKeys = ['appExceptions', 'scopedShortcutList', 'shortcutOverrides'];

/** Anchor id for a section heading. Key rows anchor on the key name itself. */
export function sectionSlug(title: string): string {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
}

/**
 * Table of contents for the reference page. The headings live in a component
 * rather than in the MDX source, so fumadocs cannot extract them itself — this
 * is handed to `DocsPage` instead, listing every key under its section.
 */
export async function configReferenceToc(locale: Locale): Promise<TOCItemType[]> {
  const t = await getTranslations({ locale, namespace: 'ConfigReference' });

  return configSections().flatMap((section) => [
    {
      title: t(`sections.${section.translationKey}.title`),
      url: `#${sectionSlug(section.title)}`,
      depth: 2,
    },
    ...section.keys.map((entry) => ({ title: entry.name, url: `#${entry.name}`, depth: 3 })),
  ]);
}

const key = (name: string): ConfigKey => ({
  name,
  fragment: properties[name] ?? {},
  default: defaults[name] ?? null,
});

export function configSections(): ConfigSection[] {
  const placed = new Set([...sections.flatMap((s) => s.keys), ...objectKeys, '$schema']);
  const orphans = Object.keys(properties)
    .filter((name) => !placed.has(name))
    .sort();

  const grouped: ConfigSection[] = sections.map((section) => ({
    ...section,
    translationKey: sectionTranslationKeys[section.title] ?? 'other',
    keys: section.keys.filter((name) => name in properties).map(key),
  }));

  if (orphans.length > 0) {
    grouped.push({
      title: 'Other',
      translationKey: 'other',
      keys: orphans.map(key),
    });
  }

  return grouped.filter((section) => section.keys.length > 0);
}

export function objectKey(name: string): ConfigKey {
  return key(name);
}

export const schemaVersion = schema.description
  .match(/BetterCmdTab ([\d.]+)/)?.[1]
  .replace(/\.$/, '');

export const totalKeyCount = Object.keys(properties).length - 1; // minus $schema
