// Auftrag: one sentence plus before -> after, with a confirm step instead of undo (owner decision, #11).
// States (ui-spec 3.5): preview (italic, confirmable), waiting (dots on the main button, everything locked),
// invalid (reason as tooltip, confirm locked), valid/normal.
import { mitTooltip } from "./tooltip.ts";
import { v, type State, type VNode } from "./vnode.ts";

export interface Change { label: string; before: string | VNode; after: string | VNode }
export interface OrderOptions {
  sentence: string;
  changes: Change[];
  state?: State;
  confirmLabel?: string;
  /** Why the order cannot be confirmed; shown as tooltip on the locked button. */
  reason?: string;
  onConfirm?: () => void;
  onCancel?: () => void;
}

export function Auftrag(o: OrderOptions): VNode {
  const state = o.state ?? "preview";
  const waiting = state === "waiting";
  const blocked = waiting || state === "invalid";
  const confirm = v("button", {
    type: "button", class: "kit-main-btn", disabled: blocked, "aria-busy": waiting ? "true" : undefined,
    onclick: () => { if (!blocked) o.onConfirm?.(); },
  }, waiting ? v("span", { class: "kit-dots", "aria-label": "Warte auf den Server" }, "•••") : (o.confirmLabel ?? "Bestätigen"));
  const cancel = v("button", { type: "button", class: "kit-side-btn", disabled: waiting, onclick: () => o.onCancel?.() }, "Abbrechen");
  const confirmCell = state === "invalid" && o.reason
    ? mitTooltip(confirm, { title: "Jetzt nicht möglich", reason: o.reason })
    : confirm;
  return v("section", { class: "kit-order", "data-state": state, "aria-live": "polite", "aria-busy": waiting ? "true" : undefined },
    v("p", { class: "kit-order-sentence" }, o.sentence),
    v("dl", { class: "kit-changes" }, ...o.changes.flatMap((c) => [
      v("dt", {}, c.label),
      v("dd", {}, v("span", { class: "kit-before" }, c.before), v("span", { class: "kit-arrow", "aria-hidden": "true" }, " → "), v("span", { class: "kit-after" }, c.after)),
    ])),
    v("div", { class: "kit-order-actions" }, confirmCell, cancel));
}
