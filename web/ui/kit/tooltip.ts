// Tooltip: German text, English rule term, breakdown lines, optional source (ui-spec 1.1, 3.5, 5.3, #112).
import { Geld } from "./money.ts";
import { v, type VChild, type VNode } from "./vnode.ts";

export interface TipRow { label: string; amount?: number; value?: string }
export interface TipContent {
  title: string;
  /** English rule term, e.g. "Certificate limit". */
  term?: string;
  /** Why an action is not possible. */
  reason?: string;
  rows?: TipRow[];
  total?: TipRow;
  /** Rulebook or issue reference, e.g. "Regeln §9.2" or "#112". */
  source?: string;
}

let counter = 0;
export function nextTipId(): string { return `kit-tip-${++counter}`; }

function row(r: TipRow, cls: string): VNode {
  return v("div", { class: cls },
    v("span", {}, r.label),
    v("span", { class: "kit-right" }, r.amount !== undefined ? Geld(r.amount) : r.value ?? ""));
}

export function Tooltip(c: TipContent, id: string): VNode {
  return v("span", { class: "kit-tip", role: "tooltip", id },
    v("strong", { class: "kit-tip-title" }, c.title),
    c.term ? v("em", { class: "kit-term" }, c.term) : null,
    c.reason ? v("span", { class: "kit-tip-reason" }, c.reason) : null,
    ...(c.rows ?? []).map((r) => row(r, "kit-tip-row")),
    c.total ? row(c.total, "kit-tip-row kit-tip-total") : null,
    c.source ? v("small", { class: "kit-tip-source" }, `Quelle: ${c.source}`) : null);
}

/** Wraps a trigger so the tooltip shows on hover and keyboard focus (CSS) and is announced (aria-describedby). */
export function mitTooltip(trigger: VNode, c: TipContent, id: string = nextTipId()): VNode {
  const described = { ...trigger, attrs: { ...trigger.attrs, "aria-describedby": id, tabindex: trigger.attrs.tabindex ?? "0" } };
  return v("span", { class: "kit-has-tip" }, described as VChild, Tooltip(c, id));
}
