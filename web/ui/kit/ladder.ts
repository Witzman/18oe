// Leiter: steps with done / active / future (ui-spec 5.3). Not colour alone: marker glyph and aria-current.
import { v, type VNode } from "./vnode.ts";

export type StepState = "done" | "active" | "future";
export interface Step { label: string; state: StepState }

const MARK: Record<StepState, string> = { done: "✓", active: "▶", future: "○" };

/** Builds steps from an ordered list and the index of the active one. */
export function stepsAt(labels: readonly string[], active: number): Step[] {
  return labels.map((label, i) => ({ label, state: i < active ? "done" : i === active ? "active" : "future" }));
}

export function Leiter(steps: readonly Step[], label: string): VNode {
  return v("ol", { class: "kit-ladder", "aria-label": label },
    ...steps.map((s) => v("li", { "data-step": s.state, "aria-current": s.state === "active" ? "step" : undefined },
      v("span", { class: "kit-mark", "aria-hidden": "true" }, MARK[s.state]), v("span", {}, s.label))));
}
