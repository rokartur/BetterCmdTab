import { buttonVariants } from "fumadocs-ui/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "fumadocs-ui/components/ui/popover";
import { useI18n } from "fumadocs-ui/contexts/i18n";
import type { LanguageSelectProps } from "fumadocs-ui/layouts/shared/slots/language-select";
import { Search } from "lucide-react";
import { useState } from "react";

const labels = {
  en: {
    choose: "Choose a language",
    search: "Search languages",
    empty: "No languages found",
  },
  pl: {
    choose: "Wybierz język",
    search: "Szukaj języka",
    empty: "Nie znaleziono języka",
  },
};

export function SearchableLanguageSelect({
  className,
  variant = "ghost",
  children,
  ...props
}: LanguageSelectProps) {
  const { locale, locales, onChange } = useI18n();
  const [query, setQuery] = useState("");

  if (!locales) throw new Error("Missing `<I18nProvider />`");

  const copy = locale === "pl" ? labels.pl : labels.en;
  const normalizedQuery = query.trim().toLocaleLowerCase(locale);
  const visibleLocales = normalizedQuery
    ? locales.filter(
        (item) =>
          item.name.toLocaleLowerCase(locale).includes(normalizedQuery) ||
          item.locale.toLocaleLowerCase(locale).includes(normalizedQuery),
      )
    : locales;

  return (
    <Popover onOpenChange={(open) => !open && setQuery("")}>
      <PopoverTrigger
        aria-label={copy.choose}
        className={({ open }) =>
          [buttonVariants({ variant }), "gap-1.5 p-1.5", open && "bg-fd-accent", className]
            .filter(Boolean)
            .join(" ")
        }
        {...props}
      >
        {children}
      </PopoverTrigger>
      <PopoverContent className="w-56 p-1">
        <p className="text-fd-muted-foreground p-2 text-xs font-medium">{copy.choose}</p>
        <label className="focus-within:ring-fd-ring flex items-center gap-2 rounded-md border px-2 focus-within:ring-2">
          <Search aria-hidden="true" className="text-fd-muted-foreground size-4 shrink-0" />
          <span className="sr-only">{copy.search}</span>
          <input
            autoFocus
            type="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={copy.search}
            autoComplete="off"
            spellCheck={false}
            className="placeholder:text-fd-muted-foreground h-9 min-w-0 flex-1 bg-transparent text-sm outline-none"
          />
        </label>
        <div className="mt-1 flex flex-col gap-0.5">
          {visibleLocales.map((item) => (
            <button
              key={item.locale}
              type="button"
              aria-current={item.locale === locale ? "true" : undefined}
              className={[
                "rounded-lg px-2 py-1.5 text-start text-sm transition-colors",
                item.locale === locale
                  ? "bg-fd-primary/10 text-fd-primary"
                  : "text-fd-muted-foreground hover:bg-fd-accent hover:text-fd-accent-foreground",
              ].join(" ")}
              onClick={() => onChange?.(item.locale)}
            >
              {item.name}
            </button>
          ))}
          {visibleLocales.length === 0 && (
            <p role="status" className="text-fd-muted-foreground px-2 py-3 text-center text-sm">
              {copy.empty}
            </p>
          )}
        </div>
      </PopoverContent>
    </Popover>
  );
}
