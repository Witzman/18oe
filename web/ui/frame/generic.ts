// The generic action bar (#45, ui-spec 3.4): every action the server offers that no special panel
// claimed, as a selectable entry; ranges as small forms. Choosing only selects: the main button of the
// action bar sends (no undo, so nothing is sent without an explicit confirm).
import type { Game, Prompt } from "../../types.ts";
import { fillText, txt } from "../text.ts";
import { v, type VNode } from "../kit/vnode.ts";
import type { Claims } from "./claims.ts";
import { playerName } from "./model.ts";

export type Action = Record<string, unknown>;
export type Range = Prompt["ranges"][number];

export interface Entry { key: string; action: Action; label: string; detail: string; danger: boolean }
export interface Group { type: string; label: string; entries: Entry[] }
export interface RangeEntry { key: string; range: Range; label: string; detail: string }
export interface GenericModel { groups: Group[]; ranges: RangeEntry[]; unsupported: string[]; count: number }

// Actions that cannot be taken back and need a second click (ui-spec 3.7).
export const DANGEROUS = new Set(["bankrupt", "discard_train", "scrap_train", "remove_token", "remove_hex_token", "manual_close_company"]);
const META_KEYS = new Set(["type", "entity", "entity_type", "id", "user", "created_at", "auto_actions"]);

export const actionKey = (a: Action): string => JSON.stringify(a);

function show(value: unknown): string {
  if (Array.isArray(value)) return value.map(show).join(", ");
  if (value !== null && typeof value === "object") return JSON.stringify(value);
  return String(value);
}

/** The engine's label of a `choose` action (#124, `prompt.choices`); null when the view lists none for it. */
export function choiceLabel(g: Game, a: Action): string | null {
  if (a.type !== "choose") return null;
  const c = g.state.prompt.choices?.find((x) => x.choice === String(a.choice) && x.entity === a.entity && (x.target ?? null) === (a.target ?? null));
  if (!c || c.label === "") return null;
  return c.target ? `${c.label} · ${fillText("frame.choice_for", { target: c.target })}` : c.label;
}

export function actionDetail(g: Game, a: Action): string {
  const labelled = choiceLabel(g, a);
  if (labelled !== null) return labelled;
  const parts = Object.entries(a).filter(([k]) => !META_KEYS.has(k)).map(([k, val]) => {
    // Dividend kinds (Rulebook 11.4) have German names; every other parameter is shown as sent.
    const kind = k === "kind" && typeof val === "string" ? txt(`dividend.${val}`) : null;
    return kind && kind.de !== `dividend.${val}` ? kind.de : `${k} ${show(val)}`;
  });
  const who = typeof a.entity === "string" && a.entity !== g.viewer ? fillText("frame.param_entity", { entity: playerName(g, a.entity) }) : "";
  return [...parts, who].filter(Boolean).join(" · ");
}

export function genericModel(g: Game, claims: Claims): GenericModel {
  const p = g.state.prompt;
  const open = (type: string) => !claims.isClaimed(p.step, type);
  const byType = new Map<string, Entry[]>();
  for (const a of p.actions) {
    const type = String(a.type ?? "");
    if (!open(type)) continue;
    const list = byType.get(type) ?? [];
    list.push({ key: actionKey(a), action: a, label: txt(`action.${type}`).de, detail: actionDetail(g, a), danger: DANGEROUS.has(type) });
    byType.set(type, list);
  }
  // A `choose` group carries the step's question (`choice_name`, #124) next to its name.
  const groupLabel = (type: string) => type === "choose" && p.choice_name ? `${txt("action.choose").de}: ${p.choice_name}` : txt(`action.${type}`).de;
  const groups: Group[] = [...byType].map(([type, entries]) => ({ type, label: groupLabel(type), entries }));
  const ranges: RangeEntry[] = p.ranges.filter((r) => open(r.type)).map((r) => ({
    key: `range:${r.type}:${r.entity}:${r.company}`, range: r, label: txt(`action.${r.type}`).de,
    detail: `${r.company} · ${fillText("frame.range_bounds", { min: r.min, max: r.max, step: r.step })}`,
  }));
  const unsupported = p.unsupported.filter((u) => !claims.isClaimed(p.step, u.split(/:\s*/).pop() ?? u));
  return { groups, ranges, unsupported, count: groups.reduce((n, gr) => n + gr.entries.length, 0) + ranges.length };
}

/** The bid a range stands for: a normal action, as the legal-action list documents (#91). */
export function rangeAction(g: Game, r: Range, price: number): Action {
  const entityType = g.state.players.some((p) => p.id === r.entity) ? "player" : "corporation";
  return { type: r.type, entity: r.entity, entity_type: entityType, company: r.company, price };
}

/** Whole number on the range's grid (min, min+step .. max); null when not. */
export function rangeValue(r: Range, input: string): number | null {
  const n = Number(input);
  if (input.trim() === "" || !Number.isInteger(n) || n < r.min || n > r.max) return null;
  return (n - r.min) % r.step === 0 ? n : null;
}

export interface GenericHandlers {
  selectedKey: string | null;
  onSelect: (entry: Entry) => void;
  onRange: (r: RangeEntry, input: string) => void;
  rangeError: { key: string; text: string } | null;
}

function entryButton(e: Entry, h: GenericHandlers): VNode {
  const selected = h.selectedKey === e.key;
  return v("button", {
    type: "button", class: "frame-entry", "data-key": e.key, "data-type": String(e.action.type),
    "aria-pressed": String(selected), "data-state": selected ? "selected" : "normal",
    onclick: () => h.onSelect(e),
  }, e.detail === "" ? e.label : e.detail);
}

export function GenericBar(m: GenericModel, h: GenericHandlers): VNode {
  const group = (gr: Group) => v("details", { class: "frame-group", "data-type": gr.type, open: gr.entries.length <= 6 },
    v("summary", {}, `${gr.label} (${gr.entries.length})`),
    v("div", { class: "frame-entries" }, ...gr.entries.map((e) => entryButton(e, h))));
  const range = (r: RangeEntry) => v("form", {
    class: "frame-range", "data-key": r.key,
    onsubmit: (ev) => {
      ev.preventDefault();
      const input = (ev.currentTarget as HTMLFormElement).elements.namedItem("price") as HTMLInputElement;
      h.onRange(r, input.value);
    },
  },
  v("strong", {}, r.label), v("span", { class: "muted" }, r.detail),
  v("label", {}, txt("frame.range_label").de, v("input", { type: "number", name: "price", min: String(r.range.min), max: String(r.range.max), step: String(r.range.step), value: String(r.range.min), required: true })),
  v("button", { type: "submit" }, txt("frame.range_pick").de),
  h.rangeError?.key === r.key ? v("span", { class: "msg-error", role: "alert" }, h.rangeError.text) : null);
  return v("div", { class: "frame-generic" },
    m.count === 0 && m.unsupported.length === 0 ? v("p", { class: "muted" }, txt("frame.generic_none").de) : null,
    ...m.groups.map(group), ...m.ranges.map(range),
    m.unsupported.length > 0 ? v("p", { class: "msg-warn" }, fillText("frame.unsupported", { list: m.unsupported.join("; ") })) : null);
}
