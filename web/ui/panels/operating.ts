// The operating sheet panel (#49, ui-spec 4.5): head and step ladder of the active corporation, the run as a
// table (auto route from the server, no route band yet), the dividend choice with amounts. It claims
// `run_routes` of the Route step and `dividend` of the Dividend step; the main button of the action bar sends
// (owner decision #137: preview first, no undo). The context slot is shared with the train panel.
import type { Game } from "../../types.ts";
import type { GameFrame } from "../frame/frame.ts";
import { Geld, Leiter, stepsAt, toDom, v, type VNode } from "../kit/index.ts";
import { fillText, txt } from "../text.ts";
import {
  DIVIDEND_STEP, LADDER, OPERATING_TYPES, ROUTE_STEP, chosenOption, dividendOptions, dividendOrder, headOf, isOperatingStep,
  ladderIndex, operator, runModel, runSentence, type DivOption,
} from "./operating-model.ts";

const tip = (key: string): string => `${txt(key).en} (${txt(key).regel})`;
const mineToAct = (g: Game): boolean => isOperatingStep(g) && g.state.prompt.viewer_to_act;

function head(g: Game): VNode | null {
  const c = operator(g);
  if (!c) return null;
  const h = headOf(c);
  const item = (key: string, ...value: (string | VNode)[]) => v("div", { title: tip(key) }, v("dt", {}, txt(key).de), v("dd", {}, ...value));
  return v("div", { class: "op-head" },
    v("h4", {}, `${h.id} · ${h.name}`, v("span", { class: "muted" }, ` ${h.tier}`)),
    v("dl", { class: "op-facts" },
      item("op.cash", Geld(h.cash)),
      h.price !== null ? item("op.price", Geld(h.price)) : null,
      item("op.trains", h.trains.length > 0 ? h.trains.join(", ") : txt("frame.none").de),
      item("op.tokens", fillText("op.token_count", { free: h.tokensFree, all: h.tokensAll }))));
}

function ladder(g: Game): VNode {
  const labels = LADDER.map((s) => txt(`step.${s}`).de);
  return Leiter(stepsAt(labels, ladderIndex(g)), txt("op.ladder").de);
}

export function RoutePanel(g: Game): VNode {
  const m = runModel(g);
  const cell = (cls: string, ...c: (string | VNode)[]) => v("td", { class: cls }, ...c);
  const extra = (key: string, n: number) => n > 0 ? v("tr", { class: "op-extra", title: tip(key) }, cell("", txt(key).de), cell("", ""), cell("op-num", Geld(n))) : null;
  return v("div", { class: "op-run" },
    v("h3", { title: tip("route.title") }, txt("route.title").de),
    m.rows.length === 0 ? v("p", { class: "muted" }, txt("route.none").de)
      : v("table", { class: "op-table" },
        v("thead", {}, v("tr", {},
          v("th", { title: tip("route.col_train") }, txt("route.col_train").de), v("th", { title: tip("route.col_stops") }, txt("route.col_stops").de),
          v("th", { class: "op-num", title: tip("route.col_revenue") }, txt("route.col_revenue").de))),
        v("tbody", {}, ...m.rows.map((r) => v("tr", { "data-train": r.train }, cell("", r.train), cell("", r.stops), cell("op-num", Geld(r.revenue)))),
          extra("route.extra", m.extra), extra("route.subsidy", m.subsidy)),
        v("tfoot", {}, v("tr", { title: tip("route.total") }, cell("", txt("route.total").de), cell("", ""), cell("op-num op-total", Geld(m.total))))),
    v("p", { class: "muted op-note" }, txt("route.note").de));
}

export interface DividendHandlers { onPick: (kind: string) => void }

function optionRow(o: DivOption, selected: boolean, mine: boolean, h: DividendHandlers): VNode {
  const num = (n: number | null) => (n === null ? "–" : Geld(n));
  const move = o.move ? txt(`div.${o.move}`).de : "";
  return v("button", {
    type: "button", class: "op-opt", "data-kind": o.kind, "aria-pressed": String(selected), disabled: !mine,
    "data-state": selected ? "selected" : "normal", title: tip(`dividend.${o.kind}`), onclick: () => h.onPick(o.kind),
  },
  v("strong", { class: "op-opt-name" }, o.label),
  v("span", { class: "op-cell" }, v("small", { class: "muted" }, txt("div.col_share").de), num(o.perShare)),
  v("span", { class: "op-cell" }, v("small", { class: "muted" }, txt("div.col_treasury").de), num(o.treasury)),
  v("span", { class: "op-cell" }, v("small", { class: "muted" }, txt("div.col_price").de), num(o.price), move ? v("small", { class: "op-move", "data-move": o.move }, ` ${move}`) : null));
}

export function DividendPanel(g: Game, pick: string | null, h: DividendHandlers): VNode {
  const mine = mineToAct(g);
  const chosen = chosenOption(g, pick);
  const revenue = g.state.prompt.context?.dividend?.revenue;
  return v("div", { class: "op-dividend" },
    v("h3", { title: tip("div.title") }, txt("div.title").de),
    revenue !== undefined ? v("p", { class: "op-revenue" }, fillText("div.revenue", { revenue: `£${revenue}` })) : null,
    v("div", { class: "op-opts", role: "group", "aria-label": txt("div.title").de },
      ...dividendOptions(g).map((o) => optionRow(o, o.kind === chosen?.kind, mine, h))));
}

export function OperatingPanel(g: Game, pick: string | null, h: DividendHandlers): VNode {
  const step = g.state.prompt.step;
  return v("section", { class: "op-panel", "aria-label": txt("op.title").de },
    head(g), ladder(g),
    step === ROUTE_STEP ? RoutePanel(g) : DividendPanel(g, pick, h),
    !g.state.prompt.viewer_to_act ? v("p", { class: "muted", role: "status" }, fillText("op.waiting", { who: operator(g)?.president ?? operator(g)?.id ?? "" })) : null);
}

export interface OperatingHandle { stop: () => void }

export function mountOperating(frame: GameFrame): OperatingHandle {
  let game: Game | null = null;
  let seq = -1;
  let pick: string | null = null;
  let owns = false;
  let releaseOrder: (() => void) | null = null;
  const releases = OPERATING_TYPES.map(([step, type]) => frame.claims.claim(step, type));
  const handlers: DividendHandlers = { onPick: (kind) => { pick = kind; draw(); } };

  function draw() {
    const g = game;
    releaseOrder?.();
    releaseOrder = null;
    if (!g || !isOperatingStep(g)) {
      if (owns) { frame.slots.context.replaceChildren(); owns = false; }
      return;
    }
    owns = true;
    frame.slots.context.replaceChildren(toDom(OperatingPanel(g, pick, handlers)));
    if (!mineToAct(g)) return;
    if (g.state.prompt.step === ROUTE_STEP) {
      const action = runModel(g).action;
      releaseOrder = frame.setOrder({
        sentence: runSentence(g), state: action ? "preview" : "invalid", reason: action ? undefined : txt("route.none").de,
        confirmLabel: txt("route.confirm").de, onConfirm: () => { if (action) frame.send(action); },
      });
    } else if (g.state.prompt.step === DIVIDEND_STEP) {
      const o = dividendOrder(g, pick);
      releaseOrder = frame.setOrder({
        sentence: o.sentence, changes: o.changes, state: o.action ? "preview" : "invalid", reason: o.action ? undefined : o.sentence,
        confirmLabel: txt("div.confirm").de, onConfirm: () => { if (o.action) frame.send(o.action); },
      });
    }
  }

  const off = frame.subscribe((g) => {
    if (g.seq !== seq) { seq = g.seq; pick = null; }
    game = g;
    draw();
  });
  return { stop: () => { off(); releaseOrder?.(); releases.forEach((r) => r()); if (owns) frame.slots.context.replaceChildren(); } };
}
