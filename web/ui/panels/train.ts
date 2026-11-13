// Train purchase panel (#175, ui-spec 4.5 "Zugkauf", rulebook 11.6): the depot as a list in the operating
// sheet, the reserved 2+2 (11.6.1) as first row marked "Pflichtkauf", trains that cannot be bought shown
// invalid with the reason, the result of a first-round insolvency (11.6.5) as a row, "Kein Zug" as side button.
// A choice only previews (sentence, before/after in the action bar); the main button sends (#137).
//
// Pure model first (tests run it under node on recorded states), then the view, then `mountTrain`.
// Everything comes from the view model (`depot`, `prompt.actions`, `prompt.context.train`); no rule check here.
import type { GameFrame } from "../frame/frame.ts";
import type { OrderSpec } from "../frame/order.ts";
import { Geld, formatGeld, toDom, v, type Change, type VNode } from "../kit/index.ts";
import type { Corporation, Game, GameState } from "../../types.ts";
import { fillText, txt } from "../text.ts";

type Action = Record<string, unknown>;
type DepotTrain = GameState["depot"]["available"][number];

export interface TrainOption { price: number; action: Action }
export interface TrainRow {
  id: string; name: string; price: number;
  /** null = Locomotive Works (the depot), else the id of the selling corporation. */
  owner: string | null;
  options: TrainOption[];
  reserved: boolean;
  /** Why the row cannot be bought; null when it can (or when it is not the viewer's turn). */
  reason: string | null;
  /** Consequence hint for the first train of its kind ("Phase 3", "2+2 rosten"); null when none. */
  hint: string | null;
  left: number | null;
}
export interface TrainSelection { train: string | null; price: number | null }
export const emptySelection = (): TrainSelection => ({ train: null, price: null });

export const isTrainStep = (g: Game): boolean => g.state.prompt.step === "BuyTrain" && !g.state.meta.finished;
const mineToAct = (g: Game): boolean => isTrainStep(g) && g.state.prompt.viewer_to_act;

/** The corporation that buys: the entity of the offered actions, else the current one of the round. */
export function buyer(g: Game): Corporation | null {
  const id = g.state.prompt.actions.find((a) => typeof a.entity === "string")?.entity ?? g.state.meta.current?.id;
  return g.state.corporations.find((c) => c.id === id) ?? null;
}

const optionsOf = (g: Game, train: DepotTrain): TrainOption[] =>
  g.state.prompt.actions.filter((a) => a.type === "buy_train" && a.train === train.id).map((a) => ({ price: Number(a.price), action: a }))
    .sort((a, b) => a.price - b.price);

/** Money the buyer may spend: its treasury plus the president's when the step lets the president chip in. */
function budget(g: Game, corp: Corporation | null): number {
  const ctx = g.state.prompt.context?.train;
  const president = corp?.president ? g.state.players.find((p) => p.id === corp.president)?.cash ?? 0 : 0;
  return (corp?.cash ?? 0) + (ctx?.president_may_contribute ? president : 0);
}

export const obligationOpen = (g: Game): boolean => {
  const ctx = g.state.prompt.context?.train;
  return !!ctx && ctx.obligation.active && !ctx.obligation.fulfilled && ctx.reserved !== null;
};

function reasonFor(g: Game, row: { name: string; price: number; reserved: boolean }, corp: Corporation | null): string {
  const ctx = g.state.prompt.context?.train;
  if (obligationOpen(g) && !row.reserved) return txt("train.invalid_reserved").de;
  if (ctx && ctx.count >= ctx.limit) return fillText("train.invalid_limit", { n: ctx.limit, phase: g.state.meta.phase.name });
  const short = row.price - budget(g, corp);
  if (short > 0) return fillText("train.invalid_cash", { missing: formatGeld(short) });
  return txt("train.invalid_now").de;
}

/** What buying this train sets off, from the schedule (#123): a new phase, trains that rust. */
function hintFor(g: Game, t: DepotTrain): string | null {
  if (t.owner !== null || g.state.depot.next !== t.name) return null;
  const sched = g.state.depot.schedule ?? [];
  const entry = sched.find((s) => s.name === t.name);
  const parts: string[] = [];
  if (entry?.phase_on && entry.phase_on !== g.state.meta.phase.name) parts.push(fillText("train.hint_phase", { phase: entry.phase_on }));
  const rust = sched.filter((s) => s.rusts_on === t.name).map((s) => s.name);
  if (rust.length > 0) parts.push(fillText("train.hint_rust", { names: rust.join(", ") }));
  return parts.length > 0 ? parts.join(" · ") : null;
}

export function trainRows(g: Game): TrainRow[] {
  if (!isTrainStep(g)) return [];
  const mine = g.state.prompt.viewer_to_act;
  const corp = buyer(g);
  const ctx = g.state.prompt.context?.train;
  const open = obligationOpen(g);
  let reservedId: string | null = null;
  if (open) reservedId = g.state.depot.available.find((t) => t.owner === null && t.name === ctx!.reserved!.name)?.id ?? null;
  const rows = g.state.depot.available.map((t): TrainRow => {
    const options = mine ? optionsOf(g, t) : [];
    const base = { id: t.id, name: t.name, price: t.price, owner: t.owner, reserved: t.id === reservedId };
    const sched = g.state.depot.schedule?.find((s) => s.name === t.name);
    return {
      ...base, options,
      reason: mine && options.length === 0 ? reasonFor(g, base, corp) : null,
      hint: hintFor(g, t),
      left: sched ? sched.count : null,
    };
  });
  return [...rows.filter((r) => r.reserved), ...rows.filter((r) => !r.reserved)];
}

/** Lines of the latest first-round insolvency (11.6.5) in the visible log tail; the engine resolves it itself. */
export function insolvencyLines(g: Game): string[] {
  const log = g.state.log.slice(-20);
  let hit = -1;
  log.forEach((l, i) => { if (/first-round insolvency/i.test(l.text)) hit = i; });
  if (hit < 0) return [];
  const action = log[hit]!.action;
  return log.filter((l) => l.action === action).map((l) => l.text);
}

/** "Zugpflicht: ..." line while the buyer has to buy; null otherwise. */
export function dutyLine(g: Game): string | null {
  const ctx = g.state.prompt.context?.train;
  const corp = buyer(g);
  if (!isTrainStep(g) || !ctx?.must_buy || !corp) return null;
  if (ctx.shortfall > 0) return fillText("train.duty_short", { corp: corp.id, cash: formatGeld(corp.cash), missing: formatGeld(ctx.shortfall) });
  return fillText("train.duty", { corp: corp.id, cash: formatGeld(corp.cash) });
}

export function effectiveSelection(g: Game, sel: TrainSelection): TrainSelection {
  const rows = trainRows(g).filter((r) => r.options.length > 0);
  // The reserved 2+2 is the only legal choice while the obligation is open: chosen already (still previewed).
  const row = rows.find((r) => r.id === sel.train) ?? (rows.length === 1 || rows[0]?.reserved ? rows[0] : undefined);
  if (!row) return emptySelection();
  const price = row.options.some((o) => o.price === sel.price) && sel.train === row.id ? sel.price : row.options.length === 1 ? row.options[0]!.price : null;
  return { train: row.id, price };
}

export interface Sentence { text: string; action: Action | null; changes: Change[]; warn: string | null }

export function sentenceFor(g: Game, sel: TrainSelection): Sentence {
  const eff = effectiveSelection(g, sel);
  const row = trainRows(g).find((r) => r.id === eff.train);
  const corp = buyer(g);
  const none = { action: null, changes: [], warn: null };
  if (!row || !corp) return { text: txt("train.sentence_pick").de, ...none };
  if (eff.price === null) return { text: fillText("train.sentence_pick_price", { train: row.name }), ...none };
  const action = row.options.find((o) => o.price === eff.price)?.action ?? null;
  const price = eff.price;
  const source = row.owner === null ? txt("train.source_works").de : fillText("train.source_corp", { corp: row.owner });
  const changes: Change[] = [{ label: fillText("train.change_cash", { who: corp.id }), before: formatGeld(corp.cash), after: formatGeld(Math.max(corp.cash - price, 0)) }];
  const chip = Math.max(price - corp.cash, 0);
  const pres = corp.president ? g.state.players.find((p) => p.id === corp.president) : undefined;
  if (chip > 0 && pres) changes.push({ label: fillText("train.change_cash", { who: pres.name }), before: formatGeld(pres.cash), after: formatGeld(pres.cash - chip) });
  const text = fillText(row.reserved ? "train.sentence_reserved" : "train.sentence", { corp: corp.id, train: row.name, price: formatGeld(price), source });
  return { text, action, changes, warn: row.hint ? fillText("train.warn", { hint: row.hint }) : null };
}

/** The order for the action bar; null when it is not the viewer's turn in this step. */
export function orderFor(g: Game, sel: TrainSelection, send: (a: Action) => void): OrderSpec | null {
  if (!mineToAct(g)) return null;
  const s = sentenceFor(g, sel);
  const pass = g.state.prompt.actions.find((a) => a.type === "pass");
  const action = s.action;
  return {
    sentence: s.text, changes: s.changes, state: action ? "preview" : "invalid", reason: action ? undefined : s.text,
    confirmLabel: txt("train.confirm").de, onConfirm: () => { if (action) send(action); },
    side: pass ? [{ label: txt("train.pass").de, onClick: () => send(pass) }] : [],
  };
}

// ---- view ---------------------------------------------------------------------------------------
export interface TrainHandlers { onTrain: (id: string) => void; onPrice: (id: string, price: number) => void }

function rowButton(r: TrainRow, selected: boolean, mine: boolean, h: TrainHandlers): VNode {
  const source = r.owner === null ? txt("train.source_works").de : fillText("train.source_corp", { corp: r.owner });
  const valid = r.options.length > 0;
  return v("button", {
    type: "button", class: "train-row", "data-train": r.id, "data-reserved": String(r.reserved), "aria-pressed": String(selected),
    "data-state": !mine ? "normal" : !valid ? "invalid" : selected ? "selected" : "normal", disabled: !valid, title: r.reason ?? undefined,
    onclick: () => h.onTrain(r.id),
  },
  v("strong", { class: "train-name" }, r.name),
  v("span", { class: "train-price" }, Geld(r.price)),
  v("span", { class: "train-source muted" }, source, r.left !== null ? ` · ${fillText("train.left", { n: r.left })}` : ""),
  r.reserved ? v("span", { class: "train-mark" }, txt("train.reserved").de) : null,
  r.hint ? v("small", { class: "train-hint muted" }, r.hint) : null,
  r.reason ? v("small", { class: "train-reason" }, r.reason) : null);
}

function priceRow(r: TrainRow, price: number | null, h: TrainHandlers): VNode {
  return v("div", { class: "train-prices", role: "group", "aria-label": fillText("train.price_row", { train: r.name }) },
    ...r.options.map((o) => v("button", {
      type: "button", class: "train-price-btn", "data-price": String(o.price), "aria-pressed": String(o.price === price),
      "data-state": o.price === price ? "selected" : "normal", onclick: () => h.onPrice(r.id, o.price),
    }, Geld(o.price))));
}

export function TrainPanel(g: Game, sel: TrainSelection, h: TrainHandlers): VNode {
  const mine = mineToAct(g);
  const eff = effectiveSelection(g, sel);
  const rows = trainRows(g);
  const chosen = rows.find((r) => r.id === eff.train);
  const duty = mine ? dutyLine(g) : null;
  const warn = mine ? sentenceFor(g, sel).warn : null;
  const ins = insolvencyLines(g);
  return v("section", { class: "train-panel", "aria-label": txt("train.title").de },
    v("h3", {}, txt("train.title").de),
    duty ? v("p", { class: "train-duty" }, duty) : null,
    rows.length === 0 ? v("p", { class: "muted" }, txt("train.depot_empty").de)
      : v("div", { class: "train-list", role: "list" }, ...rows.map((r) => rowButton(r, r.id === eff.train, mine, h))),
    chosen && chosen.options.length > 1 ? priceRow(chosen, eff.price, h) : null,
    warn ? v("p", { class: "train-warn", role: "status" }, warn) : null,
    ins.length > 0 ? v("div", { class: "train-insolvency" }, v("h4", {}, txt("train.insolvency").de), v("ul", {}, ...ins.map((t) => v("li", {}, t)))) : null);
}

// ---- mount --------------------------------------------------------------------------------------
export interface TrainHandle { stop: () => void }

export function mountTrain(frame: GameFrame): TrainHandle {
  let game: Game | null = null;
  let seq = -1;
  let sel = emptySelection();
  let releaseOrder: (() => void) | null = null;
  let owns = false;
  const releases: (() => void)[] = [];
  const handlers: TrainHandlers = {
    onTrain: (id) => { sel = { train: id, price: null }; draw(); },
    onPrice: (id, price) => { sel = { train: id, price }; draw(); },
  };

  function claim(active: boolean) {
    while (releases.length > 0) releases.pop()!();
    if (active) releases.push(frame.claims.claim("BuyTrain", "buy_train"), frame.claims.claim("BuyTrain", "pass"));
  }

  function draw() {
    const g = game;
    releaseOrder?.();
    releaseOrder = null;
    if (!g || !isTrainStep(g)) {
      claim(false);
      // Only clear what this panel drew; the context slot is shared with the other round panels.
      if (owns) { frame.slots.context.replaceChildren(); owns = false; }
      return;
    }
    claim(true);
    owns = true;
    frame.slots.context.replaceChildren(toDom(TrainPanel(g, sel, handlers)));
    const spec = orderFor(g, sel, (a) => frame.send(a));
    if (spec) releaseOrder = frame.setOrder(spec);
  }

  const off = frame.subscribe((g) => {
    if (g.seq !== seq) { seq = g.seq; sel = emptySelection(); }
    game = g;
    draw();
  });
  return { stop: () => { off(); releaseOrder?.(); claim(false); if (owns) frame.slots.context.replaceChildren(); } };
}
