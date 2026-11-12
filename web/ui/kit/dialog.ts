// Dialog: lies over the main area only, never over the round bar (ui-spec 5.3). It belongs inside the
// `.kit-main` container (position: relative, below the bar); the backdrop is absolute to it, not to the window.
import { v, type VChild, type VNode } from "./vnode.ts";

export interface DialogOptions {
  title: string;
  body: VChild[];
  actions: VNode[];
  onClose?: () => void;
  id?: string;
}

export function Dialog(o: DialogOptions): VNode {
  const titleId = `${o.id ?? "kit-dialog"}-title`;
  const key = (e: Event) => { if ((e as KeyboardEvent).key === "Escape") o.onClose?.(); };
  return v("div", { class: "kit-backdrop", onkeydown: key, onclick: (e) => { if (e.target === e.currentTarget) o.onClose?.(); } },
    v("section", { class: "kit-dialog", role: "dialog", "aria-modal": "true", "aria-labelledby": titleId },
      v("h3", { id: titleId }, o.title),
      v("div", { class: "kit-dialog-body" }, ...o.body),
      v("div", { class: "kit-dialog-actions" }, ...o.actions)));
}
