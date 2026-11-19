// Operating sheet model (#49, ui-spec 4.5): head of the active corporation, step ladder, the run as a table
// (the one route the server proposes, no route band yet, #155) and the dividend choice with amounts.
// Pure functions over the view model; tests run them under node on recorded states. No rule checks here:
// everything shown and every action sent comes from `prompt.actions` and `prompt.context.dividend`.
import type { Corporation, DividendContext, Game, RunSea } from "../../types.ts";
import { fillText, txt } from "../text.ts";
import { formatGeld, type Change } from "../kit/index.ts";
import { playerName } from "../frame/model.ts";

export type Action = Record<string, unknown>;
export const ROUTE_STEP = "Route";
export const DIVIDEND_STEP = "Dividend";
export const OPERATING_TYPES = [[ROUTE_STEP, "run_routes"], [ROUTE_STEP, "choose"], [DIVIDEND_STEP, "dividend"]] as const;

export interface PullmanOption { choice: string; label: string; action: Action }
/** The `choose` actions of the Route step whose choice starts with `prefix`, with the label the view gives them. */
function routeChoices(g: Game, prefix: string): PullmanOption[] {
  if (g.state.prompt.step !== ROUTE_STEP || !g.state.prompt.viewer_to_act) return [];
  const choices = g.state.prompt.choices ?? [];
  return g.state.prompt.actions
    .filter((a) => a.type === "choose" && typeof a.choice === "string" && a.choice.startsWith(prefix))
    .map((a) => ({ choice: String(a.choice), label: choices.find((c) => c.choice === a.choice)?.label ?? String(a.choice), action: a }));
}
/** The trains the viewer may attach the Pullman to (§11.3.9, #55): the `choose` actions `pullman_on:<train>` of the Route step. */
export const pullmanOptions = (g: Game): PullmanOption[] => routeChoices(g, "pullman_on:");
/** The port authority markers the viewer's major may still buy (§11.3.5, #56): `port_authority:<area>`; the Route step is the last that offers them. */
export const portAuthorityOptions = (g: Game): PullmanOption[] => routeChoices(g, "port_authority:");

/** Operating steps in rule order (rulebook 11); the ladder marks the current one. */
export const LADDER = ["Track", "Token", "Route", "Dividend", "BuyTrain"] as const;
const LADDER_INDEX: Record<string, number> = { Track: 0, Token: 1, HomeToken: 1, SpecialToken: 1, Route: 2, Dividend: 3, TransferTokens: 3, BuyTrain: 4 };

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
  // What each holder other than the corporation really receives (the rate times shares, rounded up per
  // recipient, §11.4); empty for withhold or when the server sent none.
  payouts: { holder: string; amount: number }[];
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
      payouts: o?.payouts ?? [],
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
  const paid = o.payouts.map((p) => `${playerName(g, p.holder)} ${formatGeld(p.amount)}`).join(", ");
  const sentence = fillText("div.sentence", { corp: corp.id, kind: o.label, share: money(o.perShare), treasury: money(o.treasury), price })
    + (paid ? ` ${fillText("div.payouts", { list: paid })}` : "");
  const changes: Change[] = [];
  if (o.treasury !== null) changes.push({ label: fillText("div.change_cash", { corp: corp.id }), before: formatGeld(corp.cash), after: formatGeld(corp.cash + o.treasury) });
  if (now !== null && o.price !== null) changes.push({ label: fillText("div.change_price", { corp: corp.id }), before: formatGeld(now), after: formatGeld(o.price) });
  return { sentence, changes, action: o.action };
}

// ---- the run on the map and in the dividend step (#302) ------------------------------------------
export interface RunLine { train: string; stops: string; revenue: number; sea: string[] }

/** The sea stretches of one run as text lines (#362): each crossing and ferry with what counts against the city limit. */
export function seaLines(r: RunSea): string[] {
  const reduction = (x: { kind: string; units: number }) =>
    fillText("route.reduction", { kind: txt(`route.reduction_${x.kind}`).de, units: x.units });
  return [
    ...(r.sea ?? []).map((s) => [fillText("route.sea", { from: s.from, to: s.to, zones: s.zones, counted: s.counted }),
      ...s.reductions.map(reduction)].join(", ")),
    ...(r.ferries ?? []).map((f) => fillText("route.ferry", { ferry: f.ferry, distance: f.distance, counted: f.counted })),
  ];
}

/** The run being decided: in the Route step the offered run_routes, in the Dividend step the stored run. */
export function runLines(g: Game): RunLine[] {
  if (g.state.prompt.step === ROUTE_STEP) return runModel(g).rows.map((r) => ({ ...r, sea: [] }));
  if (g.state.prompt.step !== DIVIDEND_STEP) return [];
  return (g.state.prompt.context?.dividend?.routes ?? []).map((r) => ({ train: r.train, stops: r.hexes.join(" – "), revenue: r.revenue, sea: seaLines(r) }));
}

/** Hexes of that run, each once, for the highlight on the map; empty when the view does not carry them. */
export function runHexes(g: Game): string[] {
  if (!isOperatingStep(g)) return [];
  const hexes = g.state.prompt.step === ROUTE_STEP
    ? (Array.isArray(runModel(g).action?.routes) ? runModel(g).action!.routes as { hexes?: unknown }[] : []).flatMap((r) => (Array.isArray(r.hexes) ? r.hexes.map(String) : []))
    : (g.state.prompt.context?.dividend?.routes ?? []).flatMap((r) => r.hexes);
  return [...new Set(hexes)];
}

/** One line per option as on the board: what each share gets, what the treasury keeps, where the price goes. */
export function optionLine(o: DivOption, now: number | null): string {
  const parts: string[] = [];
  if (o.perShare !== null && o.perShare > 0) parts.push(fillText("div.share_line", { share: formatGeld(o.perShare) }));
  if (o.treasury !== null && o.treasury > 0) parts.push(fillText("div.treasury_line", { amount: formatGeld(o.treasury) }));
  if (o.price !== null && now !== null) {
    parts.push(o.move === "same" ? txt("div.price_same").de : fillText("div.price_line", { from: formatGeld(now), to: formatGeld(o.price) }));
  }
  return parts.join(" · ");
}

/** Who gets what for the chosen option, else for the full payout (the mock's "Auszahlung bei ..."). */
export function payoutRows(g: Game, pick: string | null): { kind: string; label: string; rows: { name: string; amount: number }[] } | null {
  const opts = dividendOptions(g);
  const o = chosenOption(g, pick) ?? opts.find((x) => x.kind === "payout") ?? null;
  if (!o || o.payouts.length === 0) return null;
  return { kind: o.kind, label: o.label, rows: o.payouts.map((p) => ({ name: playerName(g, p.holder), amount: p.amount })) };
}
