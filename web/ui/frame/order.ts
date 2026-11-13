// Interface for special panels to fill the action bar (#213, ui-spec 3.4): one order sentence with
// before/after changes, exactly one main button, any number of side buttons. A panel calls
// `frame.setOrder(spec)` while it is mounted and the returned release function when it unmounts (the
// same life cycle as `frame.claims.claim`). While an order is set it replaces the generic selection in
// the bar; the generic bar itself stays available for everything nobody claimed.
import { Auftrag, type Change } from "../kit/order.ts";
import { v, type State, type VNode } from "../kit/vnode.ts";
import { txt } from "../text.ts";

export interface SideButton {
  label: string;
  onClick: () => void;
  disabled?: boolean;
  /** Why it is disabled; shown as tooltip. */
  reason?: string;
}

export interface OrderSpec {
  /** What the current selection would do, one sentence (German, from text.ts). */
  sentence: string;
  /** Before -> after lines (cash, certificates, price). */
  changes?: Change[];
  /** "preview" (default, confirmable), "valid" (normal), "invalid" (main button locked, `reason` explains). */
  state?: Extract<State, "preview" | "valid" | "invalid">;
  reason?: string;
  /** Label of the one main button; default "Ausführen". */
  confirmLabel?: string;
  /** Called on confirm. Panels send through `frame.send(action)`. */
  onConfirm: () => void;
  /** Irreversible: the first click only arms, the second click confirms (ui-spec 3.7). */
  danger?: boolean;
  /** Side buttons (pass, end step, discard); no cancel button unless one is listed here. */
  side?: SideButton[];
}

export interface OrderContext { busy: boolean; armed: boolean; onArm: () => void }

/** The bar content for a panel order: Auftrag with the main button, then the side buttons. Pure. */
export function orderView(spec: OrderSpec, ctx: OrderContext): VNode {
  const state: State = ctx.busy ? "waiting" : (spec.state ?? "preview");
  const order = Auftrag({
    sentence: spec.sentence + (spec.danger ? ` ${txt("frame.danger_note").de}` : ""),
    changes: spec.changes ?? [], state, reason: spec.reason, showCancel: false,
    confirmLabel: spec.danger && ctx.armed ? txt("frame.confirm_danger").de : (spec.confirmLabel ?? txt("frame.confirm").de),
    onConfirm: () => { if (spec.danger && !ctx.armed) ctx.onArm(); else spec.onConfirm(); },
  });
  const side = (spec.side ?? []).map((b) => v("button", {
    type: "button", class: "kit-side-btn", disabled: ctx.busy || b.disabled === true, title: b.reason, onclick: () => b.onClick(),
  }, b.label));
  return v("div", { class: "frame-order-panel" }, order, side.length > 0 ? v("div", { class: "frame-order-side" }, ...side) : null);
}

/** Holder of the current panel order. Newest set wins; a release only clears its own order. */
export function createOrderSlot(onChange: () => void) {
  let current: { spec: OrderSpec; token: object } | null = null;
  let armed = false;
  return {
    set(spec: OrderSpec): () => void {
      const token = {};
      current = { spec, token };
      armed = false;
      onChange();
      return () => { if (current?.token === token) { current = null; armed = false; onChange(); } };
    },
    get spec(): OrderSpec | null { return current?.spec ?? null; },
    get armed(): boolean { return armed; },
    arm() { armed = true; onChange(); },
  };
}
export type OrderSlot = ReturnType<typeof createOrderSlot>;
