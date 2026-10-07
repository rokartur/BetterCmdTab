import { type ReactNode, useEffect, useState } from "react";

// Real config keys and values (App/Preferences.swift). Clicking a value in the
// demo file steps to the next entry; the first entry is what the demo opens on.
const configChoices = {
  layoutMode: ["list", "iconDock", "windowPreview"],
  sortOrder: ["mru", "alphabetical", "launchOrder"],
  panelOpacity: [100, 80, 60, 40],
} as const;

type ConfigKey = keyof typeof configChoices;

const configKeys: Array<ConfigKey> = ["layoutMode", "sortOrder", "panelOpacity"];

// `icon` is the column in /demo/apps.webp and the N in /demo/win-N.webp.
const demoApps = [
  {
    name: "Helium",
    title: "BetterCmdTab: a better Cmd+Tab",
    icon: 1,
    launched: 3,
    badge: "",
    audio: false,
  },
  {
    name: "Ghostty",
    title: "~/Developer/BetterCmdTab",
    icon: 0,
    launched: 0,
    badge: "",
    audio: false,
  },
  {
    name: "Code",
    title: "GeneralSettingsViewController.swift",
    icon: 2,
    launched: 2,
    badge: "",
    audio: false,
  },
  { name: "Spotify", title: "Gibbs - Pył gwiazd", icon: 3, launched: 1, badge: "", audio: true },
  { name: "Mail", title: "All Inboxes, 1 unread", icon: 4, launched: 4, badge: "1", audio: false },
  { name: "Discord", title: "Friends", icon: 5, launched: 5, badge: "1", audio: false },
];

type DemoApp = (typeof demoApps)[number];

function sortDemoApps(order: string): Array<DemoApp> {
  const apps = [...demoApps];
  if (order === "alphabetical") apps.sort((a, b) => a.name.localeCompare(b.name));
  if (order === "launchOrder") apps.sort((a, b) => a.launched - b.launched);
  return apps;
}

// The screenshots' wallpaper in gradients: warm sand left, slate bottom, pale
// right, with the two bright fold edges as thin arcs.
const STAGE_BG = [
  "radial-gradient(120% 95% at -12% 118%, transparent 58%, rgba(255,246,230,0.6) 59.5%, transparent 62%)",
  "radial-gradient(105% 85% at 112% -22%, transparent 56%, rgba(255,250,240,0.55) 57.5%, transparent 60%)",
  "radial-gradient(60% 55% at 55% 108%, #43415a 0, #535365 35%, transparent 100%)",
  "radial-gradient(45% 70% at 104% 55%, #d8d7d0 0, transparent 100%)",
  "radial-gradient(55% 60% at 38% 0%, #e4d6c1 0, transparent 100%)",
  "radial-gradient(50% 70% at 0% 50%, #b08b57 0, transparent 100%)",
  "linear-gradient(160deg, #7a573b, #8a7462 45%, #6c6f86)",
].join(", ");

// config.json on the left, a switcher on the right that rebuilds from it the
// moment a value changes, which is the "edits apply live" claim, shown.
export function LiveConfig() {
  const [picked, setPicked] = useState<Record<ConfigKey, number>>({
    layoutMode: 0,
    sortOrder: 0,
    panelOpacity: 0,
  });
  // `n` remounts the edited line, which restarts its flash.
  const [edit, setEdit] = useState<{ key: ConfigKey; n: number } | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!saving) return;
    const timer = setTimeout(() => setSaving(false), 400);
    return () => clearTimeout(timer);
  }, [saving, edit]);

  const valueOf = (key: ConfigKey) => configChoices[key][picked[key]];

  const change = (key: ConfigKey) => {
    setPicked((p) => ({ ...p, [key]: (p[key] + 1) % configChoices[key].length }));
    setEdit((e) => ({ key, n: (e?.n ?? 0) + 1 }));
    setSaving(true);
  };

  let status = "saved";
  if (saving) status = "saving";
  else if (edit) status = "saved, applied";

  return (
    <div className="grid grid-cols-[minmax(0,1.15fr)_74px_minmax(0,1fr)] max-[860px]:grid-cols-1">
      <div className="flex flex-col gap-3.5">
        <div className="overflow-hidden rounded-[14px] border border-line bg-surface">
          <div className="flex h-[38px] items-center gap-2 border-b border-line bg-bg px-3.5 text-[12.5px] text-muted">
            <span className="mr-2 flex gap-[7px]" aria-hidden>
              <i className="size-[11px] rounded-full bg-line" />
              <i className="size-[11px] rounded-full bg-line" />
              <i className="size-[11px] rounded-full bg-line" />
            </span>
            <span className="truncate font-mono">
              ~/.config/bettercmdtab/<b className="font-medium text-text">config.json</b>
            </span>
            <span
              aria-live="polite"
              className={`ml-auto flex flex-none items-center gap-1.5 text-[12px] transition-colors duration-200 ${
                saving ? "text-muted" : "text-text"
              }`}
            >
              <i
                aria-hidden
                className={`size-1.5 rounded-full transition-colors duration-200 ${
                  saving ? "bg-muted" : "bg-[#16a34a]"
                }`}
              />
              {status}
            </span>
          </div>

          <div className="py-3.5 font-mono text-[13px] leading-[1.8]">
            <CodeLine n={1}>
              <span className="text-muted">{"{"}</span>
            </CodeLine>
            {configKeys.map((key, i) => {
              const value = valueOf(key);
              const flashing = edit?.key === key;
              return (
                <CodeLine
                  key={flashing ? `${key}-${edit.n}` : key}
                  n={i + 2}
                  className={flashing ? "animate-[line-flash_0.9s_ease-out]" : ""}
                >
                  {"  "}
                  <span className="text-text">"{key}"</span>
                  <span className="text-muted">: </span>
                  <button
                    type="button"
                    onClick={() => change(key)}
                    aria-label={`${key} is ${value}, change it`}
                    className="-mx-[3px] cursor-pointer rounded-[5px] border-0 bg-transparent px-[3px] py-px font-mono shadow-[inset_0_-1px_0_rgba(37,99,235,0.55)] transition-colors duration-150 hover:bg-accent/20 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent"
                  >
                    {typeof value === "string" ? (
                      <span className="text-accent">"{value}"</span>
                    ) : (
                      <span className="text-dim">{value}</span>
                    )}
                  </button>
                  {i < configKeys.length - 1 && <span className="text-muted">,</span>}
                </CodeLine>
              );
            })}
            <CodeLine n={configKeys.length + 2}>
              <span className="text-muted">{"}"}</span>
            </CodeLine>
          </div>
        </div>
        <p className="m-0 text-[13px] text-muted">
          Click any{" "}
          <span className="text-text shadow-[inset_0_-1px_0_rgba(37,99,235,0.7)]">
            underlined value
          </span>{" "}
          to change it.
        </p>
      </div>

      <div
        aria-hidden
        className="relative grid place-items-center before:absolute before:inset-x-0 before:top-1/2 before:h-px before:bg-[linear-gradient(90deg,var(--color-line),var(--color-accent),var(--color-line))] max-[860px]:h-14 max-[860px]:before:inset-x-auto max-[860px]:before:inset-y-0 max-[860px]:before:left-1/2 max-[860px]:before:h-auto max-[860px]:before:w-px"
      >
        <span
          className={`relative rounded-[6px] border bg-bg px-[7px] py-0.5 font-mono text-[11px] transition-colors duration-200 ${
            saving ? "border-accent text-text" : "border-line text-muted"
          }`}
        >
          live
        </span>
      </div>

      <div
        className="grid min-h-[340px] place-items-center overflow-hidden rounded-[14px] p-4"
        style={{ background: STAGE_BG }}
      >
        <MiniSwitcher
          layout={configChoices.layoutMode[picked.layoutMode]}
          apps={sortDemoApps(configChoices.sortOrder[picked.sortOrder])}
          opacity={configChoices.panelOpacity[picked.panelOpacity]}
        />
      </div>
    </div>
  );
}

function CodeLine({
  n,
  className = "",
  children,
}: {
  n: number;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div className={`grid grid-cols-[44px_1fr] whitespace-pre ${className}`}>
      <span aria-hidden className="pr-3 text-right text-muted/60 select-none">
        {n}
      </span>
      <span>{children}</span>
    </div>
  );
}

function MiniSwitcher({
  layout,
  apps,
  opacity,
}: {
  layout: string;
  apps: Array<DemoApp>;
  opacity: number;
}) {
  return (
    <div
      role="img"
      aria-label={`Switcher preview, ${layout} layout, ${apps.map((a) => a.name).join(", ")}`}
      className="rounded-[20px] border border-white/20 p-2.5 text-white shadow-[0_30px_70px_-24px_rgba(20,12,4,0.6),inset_0_1px_0_rgba(255,255,255,0.18)] backdrop-blur-[30px] backdrop-saturate-[1.4] transition-[background-color] duration-300"
      style={{ backgroundColor: `rgba(34, 30, 27, ${(0.42 * opacity) / 100 + 0.04})` }}
    >
      {layout === "list" &&
        apps.map((app, i) => (
          <div
            key={app.name}
            className={`grid h-[30px] w-[340px] grid-cols-[60px_17px_1fr_auto] items-center gap-2.5 rounded-[8px] px-2.5 text-[13px] max-[520px]:w-[270px] max-[360px]:w-[226px] ${
              i === 1 ? "bg-[#3b7ef4]" : ""
            }`}
          >
            <span className="truncate text-right">{app.name}</span>
            <AppIcon icon={app.icon} className="size-[17px]" />
            <span className="truncate">{app.title}</span>
            <Indicators app={app} selected={i === 1} />
          </div>
        ))}
      {layout === "iconDock" && (
        <div className="flex gap-1.5">
          {apps.map((app, i) => (
            <div
              key={app.name}
              className={`w-[60px] text-center text-[10.5px] leading-tight max-[520px]:w-[42px] ${
                i === 1 ? "font-semibold text-white" : "text-white/70"
              }`}
            >
              <span
                className={`mx-auto mb-1.5 flex size-[52px] rounded-[13px] p-[5px] max-[520px]:size-9 max-[520px]:p-1 ${
                  i === 1 ? "bg-[#3b7ef4]/35 shadow-[inset_0_0_0_1.5px_rgba(99,150,255,0.8)]" : ""
                }`}
              >
                <AppIcon icon={app.icon} className="size-full" />
              </span>
              <span className="block truncate">{app.name}</span>
              <span className="mt-px block truncate text-[9px] font-normal text-white/60">
                {app.title}
              </span>
            </div>
          ))}
        </div>
      )}
      {layout === "windowPreview" && (
        <div className="grid grid-cols-[repeat(3,100px)] gap-x-2 gap-y-2.5 max-[520px]:grid-cols-[repeat(3,80px)]">
          {apps.map((app, i) => (
            <div key={app.name} className="text-[9.5px]">
              <img
                src={`/demo/win-${app.icon}.webp`}
                alt=""
                width={100}
                height={62}
                loading="lazy"
                className={`block h-[62px] w-full rounded-[6px] object-cover max-[520px]:h-12 ${
                  i === 1 ? "ring-2 ring-white/85" : ""
                }`}
              />
              <span
                className={`mt-1.5 flex items-center justify-center gap-1 overflow-hidden whitespace-nowrap ${
                  i === 1 ? "text-white" : "text-white/70"
                }`}
              >
                <AppIcon icon={app.icon} className="size-3" />
                <span className="truncate">
                  {app.name} – {app.title}
                </span>
                {app.badge && <Badge text={app.badge} />}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// SwitcherIndicators.swift: audio is systemGreen, except on the opaque list selection.
function Indicators({ app, selected }: { app: DemoApp; selected: boolean }) {
  return (
    <span className="flex items-center gap-1.5">
      {app.audio && (
        <svg
          aria-hidden="true"
          viewBox="0 0 16 16"
          className={`size-3.5 ${selected ? "text-white/90" : "text-[#30d158]"}`}
        >
          <path d="M1.5 6h2.6L7.5 3v10L4.1 10H1.5z" fill="currentColor" />
          <path
            d="M10 5.8a3 3 0 0 1 0 4.4M12.2 3.8a6 6 0 0 1 0 8.4"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.4"
            strokeLinecap="round"
          />
        </svg>
      )}
      {app.badge && <Badge text={app.badge} />}
    </span>
  );
}

function Badge({ text }: { text: string }) {
  return (
    <span className="grid h-4 min-w-4 flex-none place-items-center rounded-full bg-[#ff3b30] px-[5px] text-[10px] font-semibold text-white">
      {text}
    </span>
  );
}

// Real macOS app icons, one 128px column each: Ghostty, Helium, Code, Spotify,
// Mail, Discord, Xcode.
function AppIcon({ icon, className }: { icon: number; className: string }) {
  return (
    <i
      aria-hidden="true"
      className={`inline-block flex-none bg-[url(/demo/apps.webp)] bg-[length:700%_100%] ${className}`}
      style={{ backgroundPosition: `${(icon * 100) / 6}% 0` }}
    />
  );
}
