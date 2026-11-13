// What the auction sheet shows and what the main button would do (#46, ui-spec 4.2). Pure: reads `Game`
// only, no DOM, tests run under node. No rule is rebuilt here: which lots can be bid on, and between which
// amounts, comes from `prompt.ranges` / `prompt.actions`; the card data comes from `state.auction` (#120).
import type { AuctionCard, Game } from "../../types.ts";
import { rangeAction, rangeValue, type Action, type Range } from "../frame/generic.ts";
import { playerName } from "../frame/model.ts";
import { fillText } from "../text.ts";
import { formatGeld } from "../kit/money.ts";

export const AUCTION_STEP = "WaterfallAuction";

export type Mode = "buy" | "bid";
/** Why a lot of the sheet cannot be chosen (German text), or null when it can. */
export type CardState = "pick" | "selected" | "blocked" | "idle";

export interface CardModel {
  card: AuctionCard;
  /** The offered bid range for this lot and the viewer, when there is one. */
  range: Range | null;
  top: boolean;
  /** The lot of the running open auction. */
  running: boolean;
  state: CardState;
  /** Tooltip reason when `state` is "blocked". */
  why: string | null;
}
export interface RowModel { row: number; roman: string; top: boolean; sold: boolean; cards: CardModel[] }
export interface Running {
  card: AuctionCard;
  high: { player: string; price: number } | null;
  inNames: string[];
  outNames: string[];
}
export interface SheetModel {
  rows: RowModel[];
  toAct: string[];
  passed: string[];
  running: Running | null;
  cash: number | null;
  left: number;
  mine: boolean;
}

const ROMAN = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII", "XIV", "XV", "XVI"];
export const roman = (n: number): string => ROMAN[n] ?? String(n);

const rangeOf = (g: Game, id: string): Range | null => g.state.prompt.ranges.find((r) => r.type === "bid" && r.company === id) ?? null;

export function sheetModel(g: Game, selectedId: string | null): SheetModel | null {
  const a = g.state.auction;
  if (!a) return null;
  const me = g.state.players.find((p) => p.id === g.viewer) ?? null;
  const mine = g.state.prompt.viewer_to_act;
  const current = a.current ? a.cards.find((c) => c.id === a.current) ?? null : null;
  const top = a.top_row ?? 0;
  const byRow = new Map<number, AuctionCard[]>();
  for (const c of a.cards) byRow.set(c.row, [...(byRow.get(c.row) ?? []), c]);
  const last = Math.max(0, ...byRow.keys());
  const rows: RowModel[] = [];
  for (let n = 1; n <= last; n++) {
    const cards = (byRow.get(n) ?? []).map((card): CardModel => {
      const range = mine ? rangeOf(g, card.id) : null;
      const running = current?.id === card.id;
      let state: CardState = "idle";
      let why: string | null = null;
      if (mine) {
        if (range) state = selectedId === card.id ? "selected" : "pick";
        else {
          state = "blocked";
          why = current && !running ? fillText("auction.why_running", { name: current.name })
            : me && card.min_bid > me.cash ? fillText("auction.why_cash", { amount: formatGeld(card.min_bid) })
            : fillText("auction.why_other", {});
        }
      }
      return { card, range, top: card.row === top, running, state, why };
    });
    rows.push({ row: n, roman: roman(n), top: n === top, sold: cards.length === 0, cards });
  }
  const nameOf = (ids: string[]) => ids.map((id) => playerName(g, id));
  let running: Running | null = null;
  if (current) {
    const out = g.state.players.map((p) => p.id).filter((id) => !a.open_bidders.includes(id) && id !== current.bid?.player);
    running = { card: current, high: current.bid, inNames: nameOf(a.open_bidders), outNames: nameOf(out) };
  }
  return { rows, toAct: nameOf(a.to_act), passed: nameOf(a.passed), running, cash: me?.cash ?? null, left: a.cards.length, mine };
}

export interface Selection { id: string; amount: string }

/** Buying at face value or placing a bid: only the lot, the amount and the state of the auction decide. */
export function modeFor(g: Game, card: AuctionCard, price: number): Mode {
  const a = g.state.auction;
  if (!a || a.current) return "bid";
  return card.row === a.top_row && price === card.min_bid ? "buy" : "bid";
}

export interface OrderModel {
  state: "preview" | "invalid";
  sentence: string;
  reason?: string;
  confirmLabel: string;
  changes: { label: string; before: number; after: number }[];
  /** The exact action the main button sends; null while the selection is not confirmable. */
  action: Action | null;
}

export function amountHint(r: Range): string {
  return fillText("auction.amount_hint", { min: formatGeld(r.min), max: formatGeld(r.max), step: formatGeld(r.step) });
}

export function orderModel(g: Game, sel: Selection | null): OrderModel {
  const card = sel ? g.state.auction?.cards.find((c) => c.id === sel.id) : undefined;
  const range = sel ? rangeOf(g, sel.id) : null;
  if (!sel || !card || !range) {
    return { state: "invalid", sentence: fillText("auction.none_selected", {}), reason: fillText("auction.none_reason", {}), confirmLabel: fillText("auction.bid_btn", { price: "" }).trim(), changes: [], action: null };
  }
  const price = rangeValue(range, sel.amount);
  const cash = g.state.players.find((p) => p.id === g.viewer)?.cash ?? null;
  if (price === null) {
    return { state: "invalid", sentence: fillText("auction.bid", { name: card.name, price: sel.amount === "" ? "…" : sel.amount }), reason: amountHint(range), confirmLabel: fillText("auction.bid_btn", { price: "" }).trim(), changes: [], action: null };
  }
  const mode = modeFor(g, card, price);
  const later = mode === "bid" && !g.state.auction?.current && card.row !== g.state.auction?.top_row;
  const key = mode === "buy" ? "auction.buy" : later ? "auction.bid_later" : "auction.bid";
  return {
    state: "preview",
    sentence: fillText(key, { name: card.name, price: formatGeld(price) }),
    confirmLabel: fillText(mode === "buy" ? "auction.buy_btn" : "auction.bid_btn", { price: formatGeld(price) }),
    changes: cash === null ? [] : [{ label: fillText("auction.change_cash", {}), before: cash, after: cash - price }],
    action: rangeAction(g, range, price),
  };
}

/** The pass the server offers, unchanged (it is sent as it came). */
export function passAction(g: Game): Action | null {
  return g.state.prompt.actions.find((a) => a.type === "pass") ?? null;
}

// ---- Rückblick "Eröffnung" ------------------------------------------------------------------
export interface OpeningItem { id: string; name: string; kind: "private" | "minor" | "concession"; value: number | null; faceDown: boolean }
export interface OpeningRow { player: string; name: string; seat: number; items: OpeningItem[] }

/** Who owns what from the opening packet. The kind comes from the ids (minor sym / CONn), as in the cards. */
export function openingModel(g: Game): OpeningRow[] {
  const minors = new Set(g.state.corporations.filter((c) => c.type === "minor").map((c) => c.id));
  return g.state.players.map((p, i) => ({
    player: p.id, name: p.name, seat: i + 1,
    items: p.companies.map((c) => ({
      id: c.id, name: c.name ?? c.id, value: c.value, faceDown: c.face_down,
      kind: /^CON\d+$/.test(c.id) ? "concession" : minors.has(c.id) ? "minor" : "private",
    })),
  }));
}
