// The auction sheet and the "Eröffnung" retrospective as element trees (#46, ui-spec 4.2). Pure like the
// kit: no DOM access, so tests inspect the structure under node; the panel turns it into elements.
import type { Theme } from "../../themes/schema.ts";
import type { Game } from "../../types.ts";
import { Geld, mitTooltip, Wimpel, v, type VNode } from "../kit/index.ts";
import { formatGeld } from "../kit/money.ts";
import { playerName } from "../frame/model.ts";
import { fillText, txt } from "../text.ts";
import { amountHint, type CardModel, type OpeningRow, type RowModel, type Selection, type SheetModel } from "./auction-model.ts";
import { rangeValue } from "../frame/generic.ts";

export interface SheetHandlers {
  onSelect: (id: string) => void;
  onAmount: (value: string) => void;
}

const seatOf = (g: Game, id: string): number => g.state.players.findIndex((p) => p.id === id) + 1;
const pennant = (g: Game, id: string, theme: Theme) => Wimpel({ seat: seatOf(g, id), name: playerName(g, id) }, { theme });

function cardNode(c: CardModel, g: Game, theme: Theme, h: SheetHandlers): VNode {
  const { card } = c;
  const price = card.min_bid;
  const body = [
    v("span", { class: "auction-kind", "data-kind": card.kind }, txt(`auction.kind_${card.kind}`).de),
    v("strong", { class: "auction-name" }, card.name),
    v("span", { class: "auction-price" },
      card.bid ? fillText("auction.high_bid", { amount: formatGeld(card.bid.price) }) : fillText("auction.min_bid", { amount: formatGeld(price) }),
      card.discount > 0 ? v("small", { class: "auction-discount" }, ` ${fillText("auction.discount", { amount: formatGeld(card.discount) })}`) : null),
    card.bid ? v("span", { class: "auction-buyer" }, pennant(g, card.bid.player, theme)) : null,
    card.revenue > 0 ? v("small", { class: "muted" }, fillText("auction.revenue", { amount: formatGeld(card.revenue) })) : null,
  ];
  const attrs = {
    class: "auction-card", "data-card": card.id, "data-kind": card.kind, "data-state": c.state,
    "data-running": c.running ? "true" : "false",
  };
  const tip = { title: card.name, term: txt(`auction.kind_${card.kind}`).en, reason: c.why ?? undefined, rows: [{ label: txt("auction.face_label").de, amount: card.value }], source: txt(`auction.kind_${card.kind}`).regel };
  if (c.state === "pick" || c.state === "selected") {
    const btn = v("button", { ...attrs, type: "button", "aria-pressed": String(c.state === "selected"), onclick: () => h.onSelect(card.id) }, ...body, v("span", { class: "auction-mark", "aria-hidden": "true" }, "◂"));
    return v("li", {}, mitTooltip(btn, tip));
  }
  const box = v("div", { ...attrs, "aria-disabled": c.state === "blocked" ? "true" : undefined }, ...body);
  return v("li", {}, c.why ? mitTooltip(box, tip) : box);
}

function rowNode(r: RowModel, g: Game, theme: Theme, h: SheetHandlers): VNode {
  const head = v("div", { class: "auction-rowhead" },
    v("strong", {}, fillText("auction.row", { roman: r.roman })),
    v("small", { class: "muted" }, r.sold ? txt("auction.row_sold").de : r.top ? txt("auction.row_top").de : txt("auction.row_below").de));
  return v("section", { class: "auction-row", "data-row": String(r.row), "data-top": r.top ? "true" : "false", "data-sold": r.sold ? "true" : "false" },
    head, v("ul", { class: "auction-cards" }, ...r.cards.map((c) => cardNode(c, g, theme, h))));
}

/** The form for the amount under the board: field, or fixed price when the range has one value only. */
export function bidForm(g: Game, sel: Selection | null, h: SheetHandlers): VNode | null {
  const range = sel ? g.state.prompt.ranges.find((r) => r.type === "bid" && r.company === sel.id) : undefined;
  const card = sel ? g.state.auction?.cards.find((c) => c.id === sel.id) : undefined;
  if (!sel || !range || !card) return null;
  if (range.min === range.max) return v("p", { class: "auction-bidform auction-fixed" }, v("strong", {}, card.name), " ", fillText("auction.fixed", { amount: formatGeld(range.min) }));
  const bad = rangeValue(range, sel.amount) === null;
  return v("form", { class: "auction-bidform", onsubmit: (e) => e.preventDefault() },
    v("strong", {}, card.name),
    v("label", {}, txt("auction.amount").de, v("input", {
      type: "number", name: "amount", min: String(range.min), max: String(range.max), step: String(range.step), value: sel.amount,
      inputmode: "numeric", "aria-invalid": bad ? "true" : "false", "aria-describedby": "auction-amount-hint",
      oninput: (e) => h.onAmount((e.currentTarget as HTMLInputElement).value),
    })),
    v("span", { id: "auction-amount-hint", class: bad ? "msg-error" : "muted", "data-bad": bad ? "true" : "false" }, amountHint(range)),
    card.kind === "minor" ? v("small", { class: "muted" }, txt("auction.minor_hint").de) : null);
}

export function sheetNode(m: SheetModel, g: Game, sel: Selection | null, theme: Theme, h: SheetHandlers): VNode {
  const status = [
    m.toAct.length > 0 ? fillText("auction.to_act", { names: m.toAct.join(", ") }) : null,
    m.passed.length > 0 ? fillText("auction.passed", { names: m.passed.join(", ") }) : null,
    fillText("auction.open_left", { n: m.left }),
  ].filter((s): s is string => s !== null);
  const run = m.running;
  return v("div", { class: "auction-sheet" },
    v("header", { class: "auction-head" },
      v("h2", {}, txt("auction.board").de),
      m.cash !== null ? v("span", { class: "auction-cash" }, `${txt("auction.cash").de} `, Geld(m.cash)) : null),
    v("p", { class: "auction-status muted", role: "status" }, status.join(" · ")),
    run ? v("section", { class: "auction-running", "aria-label": fillText("auction.running", { name: run.card.name }) },
      v("strong", {}, fillText("auction.running", { name: run.card.name })),
      run.high ? v("span", {}, fillText("auction.running_high", { amount: formatGeld(run.high.price), who: playerName(g, run.high.player) }), " ", pennant(g, run.high.player, theme)) : null,
      v("span", {}, fillText("auction.running_in", { names: run.inNames.join(", ") || "—" })),
      run.outNames.length > 0 ? v("span", { class: "muted" }, fillText("auction.running_out", { names: run.outNames.join(", ") })) : null) : null,
    v("div", { class: "auction-rows" }, ...m.rows.map((r) => rowNode(r, g, theme, h))),
    bidForm(g, sel, h));
}

export function openingNode(rows: OpeningRow[], theme: Theme): VNode {
  return v("div", { class: "auction-sheet auction-opening" },
    v("header", { class: "auction-head" }, v("h2", {}, txt("auction.opening_title").de)),
    v("ul", { class: "auction-players" }, ...rows.map((r) => v("li", { class: "auction-player", "data-player": r.player },
      Wimpel({ seat: r.seat, name: r.name }, { theme }),
      r.items.length === 0 ? v("span", { class: "muted" }, txt("auction.opening_none").de)
        : v("ul", { class: "auction-owned" }, ...r.items.map((i) => v("li", { "data-kind": i.kind },
          v("span", { class: "auction-kind", "data-kind": i.kind }, txt(`auction.kind_${i.kind}`).de), " ", i.name,
          i.value !== null ? v("small", { class: "muted" }, ` ${fillText("auction.opening_value", { amount: formatGeld(i.value) })}`) : null)))))));
}
