// Operating sheet model (#49, ui-spec 4.5): head of the active corporation, step ladder, the run as a table
// (the one route the server proposes, no route band yet, #155) and the dividend choice with amounts.
// Pure functions over the view model; tests run them under node on recorded states. No rule checks here:
// everything shown and every action sent comes from `prompt.actions` and `prompt.context.dividend`.
import type { Corporation, DividendContext, Game } from "../../types.ts";
import { fillText, txt } from "../text.ts";
import { formatGeld, type Change } from "../kit/index.ts";

export type Action = Record<string, unknown>;
export const ROUTE_STEP = "Route";
export const DIVIDEND_STEP = "Dividend";
export const OPERATING_TYPES = [[ROUTE_STEP, "run_routes"], [DIVIDEND_STEP, "dividend"]] as const;

/** Operating steps in rule order (rulebook 11); the ladder marks the current one. */
export const LADDER = ["Track", "Token", "Route", "Dividend", "BuyTrain"] as const;
const LADDER_INDEX: Record<string, number> = { Track: 0, Token: 1, HomeToken: 1, SpecialToken: 1, Route: 2, Dividend: 3, BuyTrain: 4 };

export const isOperatingStep = (g: Game): boolean =>
  (g.state.prompt.step === ROUTE_STEP || g.state.prompt.step === DIVIDEND_STEP) && !g.state.meta.finished;
export const ladderIndex = (g: Game): number => LADDER_INDEX[g.state.prompt.step ?? ""] ?? -1;

/** The corporation that operates: entity of the offered actions, else the current one of the round. */
export function operator(g: Game): Corporation | null {
  const id = g.state.prompt.actions.find((a) => typeof a.entity === "string")?.entity ?? g.state.meta.current?.id;
  return g.state.corporations.find((c) => c.id === id) ?? null;
}

export interface Head { id: string; name: string; tier: string; cash: number; price: number | null; trains: string[]; tokensFree: number; tokensAll: number }
export function headOf(c: Corporation): Head {
  return {
    id: c.id, name: c.name, tier: txt(`tier.${c.type}`).de, cash: c.cash, price: c.share_price,
    trains: c.trains.map((t) => t.name), tokensFree: c.tokens.filter((t) => !t.used).length, tokensAll: c.tokens.length,
  };
}

// ---- run ---------------------------------------------------------------------------------------
export interface RouteRow { train: string; stops: string; revenue: number }
export interface RunModel { action: Action | null; rows: RouteRow[]; extra: number; subsidy: number; total: number }

export function runModel(g: Game): RunModel {
  const action = g.state.prompt.actions.find((a) => a.type === "run_routes") ?? null;
  const routes = (Array.isArray(action?.routes) ? action!.routes : []) as { train?: unknown; hexes?: unknown; revenue?: unknown }[];
  const rows = routes.map((r) => ({
    train: String(r.train ?? ""), stops: Array.isArray(r.hexes) ? r.hexes.join(" – ") : "", revenue: Number(r.revenue ?? 0),
  }));
  const extra = Number(action?.extra_revenue ?? 0);
  const subsidy = Number(action?.subsidy ?? 0);
  return { action, rows, extra, subsidy, total: rows.reduce((n, r) => n + r.revenue, 0) + extra + subsidy };
}

export function runSentence(g: Game): string {
  const m = runModel(g);
  const corp = operator(g);
  if (!m.action || !corp) return txt("route.none").de;
  return fillText("route.sentence", { corp: corp.id, n: m.rows.length, revenue: formatGeld(m.total) });
}

// ---- dividend ----------------------------------------------------------------------------------
export interface DivOption {
  kind: string; label: string; action: Action; perShare: number | null; treasury: number | null; price: number | null;
  move: "up" | "down" | "same" | null;
}

export function dividendOptions(g: Game): DivOption[] {
  const ctx: DividendContext | null = g.state.prompt.context?.dividend ?? null;
  const corp = operator(g);
  return g.state.prompt.actions.filter((a) => a.type === "dividend").map((action) => {
    const kind = String(action.kind);
    const o = ctx?.options.find((x) => x.kind === kind);
    const price = o?.price ?? null;
    const now = corp?.share_price ?? null;
    return {
      kind, label: txt(`dividend.${kind}`).de, action, perShare: o?.per_share ?? null, treasury: o?.treasury ?? null, price,
      move: price === null || now === null ? null : price > now ? "up" : price < now ? "down" : "same",
    };
  });
}

/** The option chosen: the player's pick if still offered, else the only one. */
export function chosenOption(g: Game, pick: string | null): DivOption | null {
  const opts = dividendOptions(g);
  return opts.find((o) => o.kind === pick) ?? (opts.length === 1 ? opts[0]! : null);
}

export function dividendOrder(g: Game, pick: string | null): { sentence: string; changes: Change[]; action: Action | null } {
  const o = chosenOption(g, pick);
  const corp = operator(g);
  if (!o || !corp) return { sentence: txt("div.pick").de, changes: [], action: null };
  const money = (n: number | null) => (n === null ? txt("stock.unknown_value").de : formatGeld(n));
  const now = corp.share_price;
  const price = o.price !== null && now !== null && o.price !== now ? fillText("div.sentence_price", { from: formatGeld(now), to: formatGeld(o.price) }) : "";
  const sentence = fillText("div.sentence", { corp: corp.id, kind: o.label, share: money(o.perShare), treasury: money(o.treasury), price });
  const changes: Change[] = [];
  if (o.treasury !== null) changes.push({ label: fillText("div.change_cash", { corp: corp.id }), before: formatGeld(corp.cash), after: formatGeld(corp.cash + o.treasury) });
  if (now !== null && o.price !== null) changes.push({ label: fillText("div.change_price", { corp: corp.id }), before: formatGeld(now), after: formatGeld(o.price) });
  return { sentence, changes, action: o.action };
}
