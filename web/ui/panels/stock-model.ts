// What the Kursblatt (stock sheet) shows and what its main button would do (#47, ui-spec 4.4). Pure: reads
// `Game` only, no DOM, tests run under node. No rule is rebuilt here: which shares can be bought, sold or
// parred comes from `prompt.actions`; the money of each offer (cost, proceeds, price after a sale, cost of
// the president's share at a par price) comes from `prompt.context.stock`; the market grid from `state.market`.
import type { Corporation, Game, MarketCell } from "../../types.ts";
import { actionKey, type Action } from "../frame/generic.ts";
import { playerName } from "../frame/model.ts";
import { fillText, txt } from "../text.ts";
import { formatGeld } from "../kit/money.ts";

export const STOCK_STEP = "BuySellParShares";
/** Action types of the stock step this panel offers itself (the rest stays in the generic bar). */
export const STOCK_TYPES = ["buy_shares", "sell_shares", "par", "pass"] as const;

export interface BuyOffer {
  kind: "buy"; key: string; action: Action; source: string; percent: number; certs: number; price: number | null;
}
export interface SellOffer {
  kind: "sell"; key: string; action: Action; percent: number; certs: number; price: number | null; newPrice: number | null;
}
export interface ParOffer {
  kind: "par"; key: string; action: Action; price: number; cost: number | null; cell: { row: number; col: number } | null;
}
export type Offer = BuyOffer | SellOffer | ParOffer;

export type RowState = "open" | "parred" | "floated" | "converted" | "minor" | "other";
export interface CorpRow {
  id: string;
  name: string;
  tier: string;
  state: RowState;
  price: number | null;
  par: number | null;
  /** Percent in treasury (IPO), in the market, reserved for the president (inside the treasury percent). */
  treasury: number;
  market: number;
  reserved: number;
  president: string | null;
  /** The viewer's percent of this corporation. */
  mine: number;
  buys: BuyOffer[];
  sells: SellOffer[];
  pars: ParOffer[];
  /** Anything to choose in this row (the viewer to act and an offer exists). */
  actionable: boolean;
}

export interface Selection { corp: string; key: string }

const TIER_ORDER: Record<string, number> = { national: 0, major: 1, regional: 2, minor: 3 };

const sameIds = (a: string[], b: string[]) => a.length === b.length && [...a].sort().join() === [...b].sort().join();
const idsOf = (a: Action): string[] => (Array.isArray(a.shares) ? (a.shares as unknown[]).map(String) : []);

/** "price,row,col" of a par action: the cell of the market grid. */
export function parCell(shareId: string): { row: number; col: number } | null {
  const [, row, col] = shareId.split(",");
  const r = Number(row), c = Number(col);
  return Number.isInteger(r) && Number.isInteger(c) ? { row: r, col: c } : null;
}

const rowState = (c: Corporation): RowState => {
  if (c.type === "minor") return "minor";
  switch (c.regional_state) {
    case "parred": return "parred";
    case "floated": return "floated";
    case "converted": return "converted";
    case null: return c.ipoed ? "floated" : "open";
    case "unparred": return "open";
    default: return "other";
  }
};

/** Which corporation a buy/sell action is about: the corporation of its first share id ("PLM_1" -> "PLM"). */
const corpOfShare = (a: Action, corps: Corporation[]): string | null => {
  const first = idsOf(a)[0];
  if (!first) return null;
  const i = first.lastIndexOf("_");
  const id = i > 0 ? first.slice(0, i) : first;
  return corps.some((c) => c.id === id) ? id : null;
};

/** The rows of the sheet, in a stable order (tier, then price high to low, unfounded last). */
export function corpRows(g: Game): CorpRow[] {
  const corps = g.state.corporations;
  const mineList = g.state.players.find((p) => p.id === g.viewer)?.shares ?? [];
  const offers = new Map<string, { buys: BuyOffer[]; sells: SellOffer[]; pars: ParOffer[] }>();
  const slot = (id: string) => { let o = offers.get(id); if (!o) { o = { buys: [], sells: [], pars: [] }; offers.set(id, o); } return o; };
  const stock = g.state.prompt.context?.stock ?? null;
  for (const a of g.state.prompt.actions) {
    const type = String(a.type);
    if (type === "buy_shares" || type === "sell_shares") {
      const id = corpOfShare(a, corps);
      if (!id) continue;
      const b = stock?.bundles.find((x) => x.type === type && x.corporation === id && sameIds(x.shares, idsOf(a)));
      const percent = typeof a.percent === "number" ? a.percent : b?.percent ?? 0;
      const certs = idsOf(a).length;
      if (type === "buy_shares") slot(id).buys.push({ kind: "buy", key: actionKey(a), action: a, source: b?.source ?? "ipo", percent, certs, price: b?.price ?? null });
      else slot(id).sells.push({ kind: "sell", key: actionKey(a), action: a, percent, certs, price: b?.price ?? null, newPrice: b?.new_price ?? null });
    } else if (type === "par" && typeof a.corporation === "string" && typeof a.share_price === "string") {
      const cost = stock?.pars.find((x) => x.corporation === a.corporation && x.share_price === a.share_price)?.price ?? null;
      slot(a.corporation).pars.push({ kind: "par", key: actionKey(a), action: a, price: Number(a.share_price.split(",")[0]), cost, cell: parCell(a.share_price) });
    }
  }
  const mine = g.state.prompt.viewer_to_act;
  const rows: CorpRow[] = [];
  for (const c of corps) {
    const o = offers.get(c.id) ?? { buys: [], sells: [], pars: [] };
    const state = rowState(c);
    const any = o.buys.length + o.sells.length + o.pars.length > 0;
    // Minors only when something can be done with them (their cards are in the opening view); removed and
    // closed corporations are not on the sheet.
    const shown = !c.closed && state !== "other" && (c.type !== "minor" || any);
    if (!shown) continue;
    const pct = (holder: string) => c.shares.filter((s) => s.holder === holder).reduce((n, s) => n + s.percent, 0);
    rows.push({
      id: c.id, name: c.name, tier: c.type, state,
      price: c.share_price, par: c.par_price,
      treasury: pct("ipo"), market: pct("market"), reserved: c.reserved?.percent ?? 0,
      president: c.president ? playerName(g, c.president) : null,
      mine: mineList.filter((s) => s.corporation === c.id).reduce((n, s) => n + s.percent, 0),
      buys: o.buys, sells: o.sells, pars: o.pars.sort((x, y) => y.price - x.price),
      actionable: mine && any,
    });
  }
  const founded = (r: CorpRow) => (r.price !== null && r.state !== "open" ? 0 : 1);
  return rows.sort((a, b) => (TIER_ORDER[a.tier] ?? 9) - (TIER_ORDER[b.tier] ?? 9) || founded(a) - founded(b) || (b.price ?? 0) - (a.price ?? 0) || a.id.localeCompare(b.id));
}

/** The offer a selection points at, searched in the rows. */
export function offerOf(rows: CorpRow[], sel: Selection | null): Offer | null {
  if (!sel) return null;
  const row = rows.find((r) => r.id === sel.corp);
  return row ? [...row.buys, ...row.sells, ...row.pars].find((o) => o.key === sel.key) ?? null : null;
}

// ---- Kurstafel -------------------------------------------------------------------------------------------

export interface MarketCellModel {
  row: number; col: number; price: number; type: string | null;
  corps: string[];
  /** A par target of the corporation in `focus`: the cell is a valid choice. */
  valid: boolean;
  chosen: boolean;
  /** Where the price of the corporation in focus would go after the sale in the selection. */
  preview: boolean;
}
export interface MarketModel { rows: (MarketCellModel | null)[][] }

/** The cell of the market where `price` is nearest to the corporation's current one (same price can repeat). */
function nearestCell(cells: (MarketCell | null)[][], from: { row: number; col: number } | null, price: number): { row: number; col: number } | null {
  let best: { row: number; col: number; d: number } | null = null;
  cells.forEach((line, r) => line.forEach((cell, c) => {
    if (!cell || cell.price !== price) return;
    const d = from ? Math.abs(from.row - r) * 100 + Math.abs(from.col - c) : r * 100 + c;
    if (!best || d < best.d) best = { row: r, col: c, d };
  }));
  const b = best as { row: number; col: number } | null;
  return b ? { row: b.row, col: b.col } : null;
}

export function marketModel(g: Game, rows: CorpRow[], focus: string | null, sel: Selection | null): MarketModel {
  const grid = g.state.market.rows;
  const row = focus ? rows.find((r) => r.id === focus) : undefined;
  const picked = offerOf(rows, sel);
  const parCells = new Set((row?.pars ?? []).filter((p) => p.cell).map((p) => `${p.cell!.row},${p.cell!.col}`));
  const chosen = picked?.kind === "par" && picked.cell ? `${picked.cell.row},${picked.cell.col}` : null;
  let previewAt: string | null = null;
  if (picked?.kind === "sell" && picked.newPrice !== null && row) {
    const at = grid.flatMap((line, r) => line.map((cell, c) => ({ r, c, cell }))).find((x) => x.cell?.corporations.includes(row.id));
    const to = nearestCell(grid, at ? { row: at.r, col: at.c } : null, picked.newPrice);
    if (to) previewAt = `${to.row},${to.col}`;
  }
  return {
    rows: grid.map((line, r) => line.map((cell, c) => cell && {
      row: r, col: c, price: cell.price, type: cell.type, corps: cell.corporations,
      valid: parCells.has(`${r},${c}`), chosen: chosen === `${r},${c}`, preview: previewAt === `${r},${c}`,
    })),
  };
}

// ---- Auftrag -------------------------------------------------------------------------------------------

export interface OrderChange { label: string; before: number | string; after: number | string; money: boolean }
export interface StockOrder {
  action: Action | null;
  sentence: string;
  changes: OrderChange[];
  state: "preview" | "invalid";
  reason?: string;
  confirmLabel: string;
}

const pct = (n: number) => `${n} %`;

export function orderModel(g: Game, rows: CorpRow[], sel: Selection | null): StockOrder {
  const offer = offerOf(rows, sel);
  const row = sel ? rows.find((r) => r.id === sel.corp) : undefined;
  const me = g.state.players.find((p) => p.id === g.viewer);
  if (!offer || !row || !me || !g.state.prompt.viewer_to_act) {
    return { action: null, sentence: txt("stock.none_selected").de, changes: [], state: "invalid", reason: txt("stock.none_reason").de, confirmLabel: txt("stock.confirm_none").de };
  }
  const changes: OrderChange[] = [];
  const cost = offer.kind === "buy" ? offer.price : offer.kind === "par" ? offer.cost : null;
  const gain = offer.kind === "sell" ? offer.price : null;
  if (cost !== null) changes.push({ label: txt("stock.change_cash").de, before: me.cash, after: me.cash - cost, money: true });
  if (gain !== null) changes.push({ label: txt("stock.change_cash").de, before: me.cash, after: me.cash + gain, money: true });
  const certs = offer.kind === "par" ? (row.tier === "minor" ? 0 : 1) : offer.kind === "buy" ? offer.certs : -offer.certs;
  if (certs !== 0) changes.push({ label: txt("stock.change_certs").de, before: fillText("stock.certs_of", { n: me.certs, limit: me.cert_limit }), after: fillText("stock.certs_of", { n: me.certs + certs, limit: me.cert_limit }), money: false });
  if (offer.kind === "sell") {
    changes.push({ label: txt("stock.change_hold").de, before: pct(row.mine), after: pct(row.mine - offer.percent), money: false });
    if (offer.newPrice !== null && row.price !== null && offer.newPrice !== row.price) changes.push({ label: txt("stock.change_price").de, before: row.price, after: offer.newPrice, money: true });
  }
  if (offer.kind === "buy") changes.push({ label: txt("stock.change_hold").de, before: pct(row.mine), after: pct(row.mine + offer.percent), money: false });
  const money = (n: number | null) => (n === null ? "—" : formatGeld(n));
  const sentence = offer.kind === "buy"
    ? fillText(offer.source === "market" ? "stock.buy_market" : "stock.buy_ipo", { corp: row.id, pct: offer.percent, price: money(offer.price) })
    : offer.kind === "sell"
      ? fillText("stock.sell", { corp: row.id, pct: offer.percent, price: money(offer.price) })
      : fillText(row.tier === "minor" ? "stock.par_minor" : "stock.par", { corp: row.id, par: formatGeld(offer.price), cost: money(offer.cost) });
  const confirmLabel = offer.kind === "buy" ? txt("stock.confirm_buy").de : offer.kind === "sell" ? txt("stock.confirm_sell").de : txt("stock.confirm_par").de;
  return { action: offer.action, sentence, changes, state: "preview", confirmLabel };
}

/** The pass action of the step, when the server offers one. */
export const passAction = (g: Game): Action | null => g.state.prompt.actions.find((a) => a.type === "pass") ?? null;

export interface MustSell { certs: number; limit: number }
/** The viewer must sell (over the limit, too many privates): the server offers selling or giving up but no pass. */
export function mustSell(g: Game): MustSell | null {
  const p = g.state.prompt;
  if (p.step !== STOCK_STEP || !p.viewer_to_act || p.actions.length === 0) return null;
  const types = new Set(p.actions.map((a) => String(a.type)));
  if (types.has("pass") || !(types.has("sell_shares") || types.has("choose"))) return null;
  const me = g.state.players.find((x) => x.id === g.viewer);
  return me ? { certs: me.certs, limit: me.cert_limit } : { certs: 0, limit: 0 };
}

/** Why a row has nothing to choose, only from numbers in the view (ui-spec 3.5); null when it is merely not offered. */
export function blockedReason(g: Game, r: CorpRow): string | null {
  if (!g.state.prompt.viewer_to_act || r.actionable || r.tier === "minor") return null;
  if (r.state === "open") return txt("stock.why_unfounded").de;
  return null;
}
