// Siegel(corp): round seal, abbreviation on the company colour (ui-spec 1.2, 5.3).
// The colour comes from the data (engine colour, later theme `companies`, #99); the text colour
// is computed per theme. The only place a company colour is shown on a panel.
import type { Theme } from "../../themes/schema.ts";
import { inkFor } from "./ink.ts";
import { v, type State, type VNode } from "./vnode.ts";

export interface Corp { sym: string; name?: string; color: string }
export interface SealOptions { theme: Theme; state?: State; size?: "s" | "m" | "l"; link?: string }

// Longer abbreviations get a smaller font so the text stays inside the seal (#198).
const sealScale = (sym: string) => sym.length <= 2 ? "" : `;--seal-fs:${sym.length === 3 ? .32 : .25}`;

export function Siegel(corp: Corp, o: SealOptions): VNode {
  const state = o.state ?? "normal";
  const ink = inkFor(corp.color, o.theme);
  const label = corp.name ? `${corp.sym}, ${corp.name}` : corp.sym;
  const attrs = {
    class: `kit-seal kit-${o.size ?? "m"}`,
    "data-state": state,
    style: `--seal-bg:${corp.color};--seal-ink:${ink}${sealScale(corp.sym)}`,
    title: label,
    "aria-label": label,
    "aria-disabled": state === "invalid" ? "true" : undefined,
    "aria-current": state === "selected" ? "true" : undefined,
  };
  // Every company is clickable and leads to its detail (5.3): a link when a target is given.
  return o.link ? v("a", { ...attrs, href: o.link }, corp.sym) : v("span", attrs, corp.sym);
}
