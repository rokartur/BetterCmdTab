import { type ReactNode, useState } from "react";

import { Kbd } from "./Keys";
import { H2 } from "./tokens";

type Mark = "yes" | "no" | "pro";
type Cell = Mark | [mark: Mark, label: ReactNode];

const markLabel: Record<Mark, string> = { yes: "Yes", no: "No", pro: "Pro" };

const products: Array<{ name: string; proPrice?: string }> = [
  { name: "BetterCmdTab" },
  { name: "Built-in" },
  { name: "AltTab", proPrice: "$9.99" },
];

type Row = [feature: ReactNode, cells: [ours: Cell, builtIn: Cell, altTab: Cell]];

// AltTab cells follow alt-tab.app (Free vs Pro table, /features) and lwouis/alt-tab-macos@56891e0
// (Pro gates in src/pro/ProFeature.swift, settings in src/preferences/Preferences.swift).
const comparisonGroups: Array<{ label: string; rows: Array<Row> }> = [
  {
    label: "switching",
    rows: [
      ["Switch windows, not just apps", ["yes", ["no", "Current app only"], "yes"]],
      ["Tap to switch, hold to open", ["yes", "yes", "yes"]],
      [
        <>
          Stay open after releasing <Kbd>⌘</Kbd>
        </>,
        ["yes", "no", "yes"],
      ],
      [
        "Cycle the front app's windows",
        ["yes", ["yes", <Kbd key="cmd-backtick">⌘`</Kbd>], ["pro", "Pro, extra shortcut"]],
      ],
      ["Type to search", ["yes", "no", "pro"]],
      ["Launch any installed app", ["yes", "no", "no"]],
      ["Multiple shortcuts", ["yes", "no", ["pro", "Pro, up to 9"]]],
      ["Hotkey per app", ["yes", "no", "no"]],
      ["Trackpad swipe to open", ["yes", "no", "yes"]],
    ],
  },
  {
    label: "layouts",
    rows: [
      ["Live window previews", ["yes", "no", "yes"]],
      ["App icon grid", ["yes", "yes", "pro"]],
      ["Window title list", ["yes", "no", "pro"]],
    ],
  },
  {
    label: "tabs",
    rows: [
      ["Browser tab drill-in", ["yes", "no", "no"]],
      ["Tabs as separate rows", ["yes", "no", ["yes", "Native tabs only"]]],
    ],
  },
  {
    label: "windows",
    rows: [
      ["Close, minimize, hide, quit", ["yes", ["no", "Quit and hide only"], "yes"]],
      ["Action buttons on hover", ["yes", "no", "yes"]],
      ["Force quit hung apps", ["yes", "no", "no"]],
      ["Window tiling", ["yes", ["yes", "macOS 15+"], "no"]],
      ["Move window to another display", ["yes", "no", "no"]],
      ["Reopen recently closed apps", ["yes", "no", "no"]],
    ],
  },
  {
    label: "filters",
    rows: [
      ["Minimized and hidden windows", ["yes", "no", "yes"]],
      ["Windows from all Spaces", ["yes", "no", "yes"]],
      ["Sort order options", ["yes", "no", "yes"]],
      ["Pin favorites", ["yes", "no", "no"]],
      ["Per-app hide and ignore rules", ["yes", "no", "yes"]],
    ],
  },
  {
    label: "status",
    rows: [
      ["Dock badge counts", ["yes", "yes", "yes"]],
      ["Playing audio indicator", ["yes", "no", "no"]],
    ],
  },
  {
    label: "system",
    rows: [
      ["Hidden from screen sharing", [["yes", "macOS 14.6+"], "no", "no"]],
      ["Export and import settings", ["yes", "no", "yes"]],
      ["Live JSON config file", ["yes", "no", "no"]],
      ["Open source", ["yes", "no", "yes"]],
    ],
  },
];

const comparison = comparisonGroups.flatMap((group) => group.rows);

function splitCell(cell: Cell): [Mark, ReactNode] {
  return typeof cell === "string" ? [cell, markLabel[cell]] : cell;
}

const labelClass: Record<Mark, string> = { yes: "text-text", no: "text-muted", pro: "text-pro" };

function fillClass(mark: Mark, ours: boolean) {
  if (mark === "pro") return "bg-pro";
  if (mark === "no") return "bg-line";
  return ours ? "bg-accent" : "bg-text";
}

export function Compare() {
  const total = comparison.length;
  // Phones show BetterCmdTab against one rival; three columns do not fit.
  const [rival, setRival] = useState(2);
  const phoneHidden = (column: number) =>
    column === 0 || column === rival ? "" : "max-[640px]:hidden";
  return (
    // Google built the snippet from these score cells ("31 · Free ; Built-in. 5 ...").
    <section id="compare" data-nosnippet>
      <h2 className={H2}>Compared.</h2>
      <div
        role="group"
        aria-label="Compare with"
        className="mb-5 hidden grid-cols-2 rounded-[10px] bg-line/70 p-[3px] max-[640px]:grid"
      >
        {[2, 1].map((column) => (
          <button
            key={column}
            type="button"
            aria-pressed={rival === column}
            onClick={() => setRival(column)}
            className={`cursor-pointer rounded-lg border-0 py-2 text-[13px] font-medium transition-colors ${
              rival === column
                ? "bg-surface text-text shadow-[0_1px_2px_rgba(0,0,0,0.15)]"
                : "bg-transparent text-dim"
            }`}
          >
            vs {products[column].name}
          </button>
        ))}
      </div>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[620px] table-fixed border-collapse text-[14px] max-[640px]:block max-[640px]:min-w-0">
          <colgroup>
            <col className="w-[34%]" />
            <col />
            <col />
            <col />
          </colgroup>
          <thead className="max-[640px]:block">
            <tr className="border-b border-line max-[640px]:grid max-[640px]:grid-cols-2 max-[640px]:gap-x-4">
              <th
                scope="col"
                className="pb-5 text-left align-bottom font-mono text-[12px] font-normal text-muted max-[640px]:hidden"
              >
                {total} features
              </th>
              {products.map((product, column) => {
                const ours = column === 0;
                const marks = comparison.map(([, cells]) => splitCell(cells[column])[0]);
                const yes = marks.filter((mark) => mark === "yes").length;
                const pro = marks.filter((mark) => mark === "pro").length;
                return (
                  <th
                    key={product.name}
                    scope="col"
                    className={`px-4 pb-5 text-left align-bottom font-normal max-[640px]:px-0 ${phoneHidden(column)}`}
                  >
                    <div className={`text-[15px] font-semibold ${ours ? "text-accent" : ""}`}>
                      {product.name}
                    </div>
                    <div className="mt-2.5 text-[34px] leading-[1.1] font-bold tracking-[-0.03em] tabular-nums">
                      {yes}
                      <span className="text-[15px] font-medium tracking-normal text-muted">
                        {" "}
                        / {total}
                      </span>
                    </div>
                    <div aria-hidden="true" className="mt-2.5 flex h-1 gap-0.5">
                      <i
                        className={`rounded-[1px] ${fillClass("yes", ours)}`}
                        style={{ flexGrow: yes }}
                      />
                      {pro > 0 && <i className="rounded-[1px] bg-pro" style={{ flexGrow: pro }} />}
                      <i
                        className="rounded-[1px] bg-line"
                        style={{ flexGrow: total - yes - pro }}
                      />
                    </div>
                    <div className="mt-2 text-[12px] text-muted">
                      {pro > 0 ? `+${pro} with Pro, ${product.proPrice}` : "Free"}
                    </div>
                  </th>
                );
              })}
            </tr>
          </thead>
          {comparisonGroups.map((group) => (
            <tbody key={group.label} className="max-[640px]:block">
              <tr className="max-[640px]:block">
                <th
                  scope="rowgroup"
                  colSpan={4}
                  className="pt-8 pb-2.5 text-left font-mono text-[12px] font-normal text-muted max-[640px]:block"
                >
                  {group.label}
                </th>
              </tr>
              {group.rows.map(([feature, cells], row) => (
                <tr
                  key={row}
                  className="border-b border-line/60 max-[640px]:grid max-[640px]:grid-cols-2 max-[640px]:gap-x-4 max-[640px]:gap-y-1 max-[640px]:py-2.5"
                >
                  <th
                    scope="row"
                    className="py-[11px] pr-4 text-left font-normal text-dim max-[640px]:col-span-2 max-[640px]:p-0"
                  >
                    {feature}
                  </th>
                  {cells.map((cell, column) => {
                    const [mark, label] = splitCell(cell);
                    return (
                      <td
                        key={products[column].name}
                        className={`px-4 py-[11px] max-[640px]:p-0 max-[640px]:text-[13px] ${phoneHidden(column)}`}
                      >
                        <span
                          aria-hidden="true"
                          className={`mr-2.5 inline-block size-2 rounded-full align-[1px] ${
                            mark === "no"
                              ? "shadow-[inset_0_0_0_1.5px_#cfcac0]"
                              : fillClass(mark, column === 0)
                          }`}
                        />
                        <span className={labelClass[mark]}>{label}</span>
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          ))}
        </table>
      </div>
    </section>
  );
}
