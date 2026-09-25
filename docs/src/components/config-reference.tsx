import { useTranslations } from 'next-intl';

import {
  configSections,
  objectKey,
  sectionSlug,
  type ConfigKey,
  type SchemaFragment,
} from '@/lib/config-reference';

/** `50…150`, an exact item count, or nothing when the type is unconstrained. */
function constraint(
  fragment: SchemaFragment,
  exactItems: (count: number) => string,
): string | null {
  if (fragment.minimum !== undefined && fragment.maximum !== undefined) {
    return `${fragment.minimum}…${fragment.maximum}`;
  }
  if (fragment.minItems !== undefined && fragment.minItems === fragment.maxItems) {
    return exactItems(fragment.minItems);
  }
  return null;
}

function Type({
  fragment,
  anyLabel,
  exactItems,
}: {
  fragment: SchemaFragment;
  anyLabel: string;
  exactItems: (count: number) => string;
}) {
  const range = constraint(fragment, exactItems);
  return (
    <>
      <code>{fragment.type ?? anyLabel}</code>
      {range ? <span className="text-fd-muted-foreground"> {range}</span> : null}
    </>
  );
}

/** Allowed values as a definition list, keeping each value next to its UI label. */
function Values({ fragment }: { fragment: SchemaFragment }) {
  if (!fragment.enum) return null;
  return (
    <ul className="my-1 list-none space-y-0.5 p-0">
      {fragment.enum.map((value, i) => (
        <li key={value} className="p-0">
          <code>{JSON.stringify(value)}</code>
          {fragment.enumDescriptions?.[i] ? (
            <span className="text-fd-muted-foreground"> — {fragment.enumDescriptions[i]}</span>
          ) : null}
        </li>
      ))}
    </ul>
  );
}

function KeyRow({
  entry,
  anyLabel,
  defaultLabel,
  exactItems,
}: {
  entry: ConfigKey;
  anyLabel: string;
  defaultLabel: string;
  exactItems: (count: number) => string;
}) {
  return (
    <tr>
      <td className="align-top whitespace-nowrap">
        {/* Anchor target for the generated table of contents. */}
        <code id={entry.name} className="scroll-mt-24">
          {entry.name}
        </code>
      </td>
      <td className="align-top whitespace-nowrap">
        <Type fragment={entry.fragment} anyLabel={anyLabel} exactItems={exactItems} />
      </td>
      <td className="align-top whitespace-nowrap" data-label={defaultLabel}>
        {entry.default ? <code>{entry.default}</code> : <span aria-hidden>—</span>}
      </td>
      <td className="align-top">
        {entry.fragment.description}
        <Values fragment={entry.fragment} />
      </td>
    </tr>
  );
}

/** Every grouped scalar/array key, as one table per section. */
export function ConfigReference() {
  const t = useTranslations('ConfigReference');
  const exactItems = (count: number) => t('exactItems', { count });
  const anyLabel = t('any');

  return (
    <>
      {configSections().map((section) => (
        <section key={section.title}>
          <h2 id={sectionSlug(section.title)}>{t(`sections.${section.translationKey}.title`)}</h2>
          <p>{t(`sections.${section.translationKey}.blurb`)}</p>
          <table className="config-table">
            <thead>
              <tr>
                <th>{t('key')}</th>
                <th>{t('type')}</th>
                <th>{t('default')}</th>
                <th>{t('description')}</th>
              </tr>
            </thead>
            <tbody>
              {section.keys.map((entry) => (
                <KeyRow
                  key={entry.name}
                  entry={entry}
                  anyLabel={anyLabel}
                  defaultLabel={t('default')}
                  exactItems={exactItems}
                />
              ))}
            </tbody>
          </table>
        </section>
      ))}
    </>
  );
}

/**
 * One array-of-objects key: its own description plus a table of the fields an
 * element may carry. Required fields are marked; everything else is optional and
 * falls back to the global setting of the same name.
 */
export function ConfigObject({ name }: { name: string }) {
  const t = useTranslations('ConfigReference');
  const exactItems = (count: number) => t('exactItems', { count });
  const anyLabel = t('any');
  const entry = objectKey(name);
  const item = entry.fragment.items;
  const properties = item?.properties ?? {};
  const required = new Set(item?.required ?? []);
  const names = Object.keys(properties).sort(
    (a, b) => Number(required.has(b)) - Number(required.has(a)) || a.localeCompare(b),
  );

  return (
    <>
      <p>{entry.fragment.description}</p>
      <table className="config-table">
        <thead>
          <tr>
            <th>{t('field')}</th>
            <th>{t('type')}</th>
            <th>{t('description')}</th>
          </tr>
        </thead>
        <tbody>
          {names.map((field) => (
            <tr key={field}>
              <td className="align-top whitespace-nowrap">
                <code>{field}</code>
                {required.has(field) ? (
                  <span className="text-fd-muted-foreground"> {t('required')}</span>
                ) : null}
              </td>
              <td className="align-top whitespace-nowrap">
                <Type fragment={properties[field]} anyLabel={anyLabel} exactItems={exactItems} />
              </td>
              <td className="align-top">
                {properties[field].description}
                <Values fragment={properties[field]} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </>
  );
}
