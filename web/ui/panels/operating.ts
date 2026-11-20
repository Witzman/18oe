// The operating sheet panel (#49, ui-spec 4.5; compact for the action panel in #302): the run as a short
// table (auto route from the server) and the dividend choice, one line per option with what it does. The head
// of the acting company and the step strip are drawn by the frame above (op-sheet.ts); no rules text here.
// It claims `run_routes` of the Route step and `dividend` of the Dividend step; the main button of the action
// bar sends (owner decision #137: preview first, no undo). The run's hexes glow on the map (assumption until
// the route band #155: the target highlight is reused). The context slot is shared with the train panel.
import type { Game } from "../../types.ts";
import type { GameFrame } from "../frame/frame.ts";
import { Geld, formatGeld, toDom, v, type VNode } from "../kit/index.ts";
import { fillText, txt } from "../text.ts";
import {
  DIVIDEND_STEP, OPERATING_TYPES, ROUTE_STEP, chosenOption, dividendOptions, dividendOrder, isOperatingStep,
  operator, optionLine, orientRequired, payoutRows, portAuthorityOptions, portSign, pullmanOptions, runBands, runHexes, runLines, runModel, runSentence, type DivOption,
} from "./operating-model.ts";
import { mapPick } from "./map-pick.ts";

const tip = (key: string): string => `${txt(key).en} (${txt(key).regel})`;
const mineToAct = (g: Game): boolean => isOperatingStep(g) && g.state.prompt.viewer_to_act;

export function RoutePanel(g: Game, onPullman?: (action: Record<string, unknown>) => void): VNode {
  const m = runModel(g);
  const pullman = pullmanOptions(g);
  const marker = portAuthorityOptions(g);
  const cell = (cls: string, ...c: (string | VNode)[]) => v("td", { class: cls }, ...c);
  const extra = (key: string, n: number) => n > 0 ? v("tr", { class: "op-extra", title: tip(key) }, cell("", txt(key).text), cell("", ""), cell("op-num", Geld(n))) : null;
  const duty = orientRequired(g);
  return v("div", { class: "op-run" },
    duty ? v("p", { class: "op-required", role: "status", title: tip("route.orient_required") }, txt("route.orient_required").text) : null,
    m.rows.length === 0 ? (duty ? null : v("p", { class: "muted" }, txt("route.none").text))
      : v("table", { class: "op-table" },
        v("thead", {}, v("tr", {},
          v("th", { title: tip("route.col_train") }, txt("route.col_train").text), v("th", { title: tip("route.col_stops") }, txt("route.col_stops").text),
          v("th", { class: "op-num", title: tip("route.col_revenue") }, txt("route.col_revenue").text))),
        v("tbody", {}, ...m.rows.map((r) => v("tr", { "data-train": r.train }, cell("", r.train), cell("op-stops", r.stops), cell("op-num", Geld(r.revenue)))),
          extra("route.extra", m.extra), extra("route.subsidy", m.subsidy)),
        v("tfoot", {}, v("tr", { title: tip("route.total") }, cell("", txt("route.total").text), cell("", ""), cell("op-num op-total", Geld(m.total))))),
    pullman.length > 0 ? v("div", { class: "op-pullman", role: "group", "aria-label": txt("route.pullman").text },
      v("p", { class: "op-payouts-title muted" }, txt("route.pullman").text),
      ...pullman.map((o) => v("button", { type: "button", class: "op-opt", "data-pullman": o.choice, onclick: () => onPullman?.(o.action) }, v("strong", { class: "op-opt-name" }, o.label)))) : null,
    marker.length > 0 ? v("div", { class: "op-pullman", role: "group", "aria-label": txt("route.port_authority").text },
      v("p", { class: "op-payouts-title muted", title: tip("route.port_authority") }, txt("route.port_authority").text),
      v("div", { class: "op-signs" }, ...marker.map((o) => {
        const sign = portSign(o);
        const name = txt(`op.port_authority_${sign.area}`);
        // The sign of the board (#478): area name and the engine's price; the full engine label stays as tooltip.
        return v("button", { type: "button", class: "op-opt op-sign", "data-port-authority": o.choice, "data-area": sign.area, title: o.label, onclick: () => onPullman?.(o.action) },
          v("strong", { class: "op-opt-name" }, name.text === `op.port_authority_${sign.area}` ? o.label : name.text),
          sign.price ? v("span", { class: "op-sign-price" }, sign.price) : null);
      }))) : null);
}

export interface DividendHandlers { onPick: (kind: string) => void; onPullman?: (action: Record<string, unknown>) => void }

function optionRow(o: DivOption, now: number | null, selected: boolean, mine: boolean, h: DividendHandlers): VNode {
  return v("button", {
    type: "button", class: "op-opt", "data-kind": o.kind, "aria-pressed": String(selected), disabled: !mine,
    "data-state": selected ? "selected" : "normal", title: tip(`dividend.${o.kind}`), onclick: () => h.onPick(o.kind),
  },
  v("strong", { class: "op-opt-name" }, o.label),
  v("span", { class: "op-opt-line" }, optionLine(o, now) || "–",
    o.move === "up" || o.move === "down" ? v("span", { class: "op-move", "data-move": o.move, title: txt(`div.${o.move}`).text }, o.move === "up" ? " ▲" : " ▼") : null));
}

export function DividendPanel(g: Game, pick: string | null, h: DividendHandlers): VNode {
  const mine = mineToAct(g);
  const chosen = chosenOption(g, pick);
  const revenue = g.state.prompt.context?.dividend?.revenue;
  const now = operator(g)?.share_price ?? null;
  const lines = runLines(g);
  const pay = payoutRows(g, pick);
  return v("div", { class: "op-dividend" },
    revenue !== undefined ? v("p", { class: "op-revenue", title: tip("div.revenue") }, v("span", {}, txt("div.run").text), v("b", {}, formatGeld(revenue))) : null,
    lines.length > 0 ? v("p", { class: "op-runlines muted" }, lines.map((l) => `${l.train}: ${l.stops} ${formatGeld(l.revenue)}`).join(" · ")) : null,
    lines.some((l) => l.sea.length > 0) ? v("ul", { class: "op-sealines muted", title: txt("route.sea_help").text },
      ...lines.flatMap((l) => l.sea.map((s) => v("li", {}, `${l.train}: ${s}`)))) : null,
    v("div", { class: "op-opts", role: "group", "aria-label": txt("div.title").text },
      ...dividendOptions(g).map((o) => optionRow(o, now, o.kind === chosen?.kind, mine, h))),
    pay ? v("div", { class: "op-payouts", "data-kind": pay.kind },
      v("p", { class: "op-payouts-title muted" }, fillText("div.payout_title", { kind: pay.label })),
      v("ul", {}, ...pay.rows.map((r) => v("li", {}, v("span", {}, r.name), v("b", {}, formatGeld(r.amount)))))) : null);
}

export function OperatingPanel(g: Game, pick: string | null, h: DividendHandlers): VNode {
  const step = g.state.prompt.step;
  return v("section", { class: "op-panel", "aria-label": txt("op.title").text },
    step === ROUTE_STEP ? RoutePanel(g, h.onPullman) : DividendPanel(g, pick, h),
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
  const handlers: DividendHandlers = { onPick: (kind) => { pick = kind; draw(); }, onPullman: (action) => frame.send(action) };
  const mapMarks = mapPick(frame);

  function draw() {
    const g = game;
    releaseOrder?.();
    releaseOrder = null;
    if (!g || !isOperatingStep(g)) {
      if (owns) { frame.slots.context.replaceChildren(); owns = false; mapMarks.show(null, null); }
      return;
    }
    owns = true;
    const hexes = runHexes(g);
    mapMarks.show(hexes.length > 0 ? { hexes, kind: "route" } : null, null, runBands(g));
    frame.slots.context.replaceChildren(toDom(OperatingPanel(g, pick, handlers)));
    if (!mineToAct(g)) return;
    if (g.state.prompt.step === ROUTE_STEP) {
      const action = runModel(g).action;
      releaseOrder = frame.setOrder({
        sentence: runSentence(g), state: action ? "preview" : "invalid", reason: action ? undefined : txt("route.none").text,
        confirmLabel: txt("route.confirm").text, onConfirm: () => { if (action) frame.send(action); },
      });
    } else if (g.state.prompt.step === DIVIDEND_STEP) {
      const o = dividendOrder(g, pick);
      releaseOrder = frame.setOrder({
        sentence: o.sentence, changes: o.changes, state: o.action ? "preview" : "invalid", reason: o.action ? undefined : o.sentence,
        confirmLabel: txt("div.confirm").text, onConfirm: () => { if (o.action) frame.send(o.action); },
      });
    }
  }

  const off = frame.subscribe((g) => {
    if (g.seq !== seq) { seq = g.seq; pick = null; }
    game = g;
    draw();
  });
  return { stop: () => { off(); releaseOrder?.(); releases.forEach((r) => r()); mapMarks.stop(); if (owns) frame.slots.context.replaceChildren(); } };
}
