// The Kursblatt as an element tree (#47, ui-spec 4.4): the share list ("Kurszettel", one row per
// corporation, the offers of the focused row as buttons) and the market grid ("Kurstafel") with the
// corporations' seals on their cells. Pure like the kit: no DOM access; tests look at the tree under node.
// Every target is a real button (at least `--shape-hit` high, no hover needed): the page works on a tablet.
import type { Theme } from "../../themes/schema.ts";
import type { Game } from "../../types.ts";
import { corpColor, playerName } from "../frame/model.ts";
import { Auftrag, Dialog, Geld, inkFor, playerSlot, Siegel, v, type VNode } from "../kit/index.ts";
import { formatGeld } from "../kit/money.ts";
import { fillText, txt } from "../text.ts";
import type { Kind } from "../frame/kinds.ts";
import { blockedReason, holdings, inTab, isMarketKind, offerOf, offersFor, orderModel, rowsForKind, sealStack, type BuyOffer, type CorpRow, type MarketCellModel, type MarketModel, type Mode, type MustSell, type Offer, type ParOffer, type SellOffer, type Selection, type Tab } from "./stock-model.ts";

export interface SheetHandlers {
  /** A corporation card: opens the dialog to buy or found (#408). */
  onFocus: (corp: string) => void;
  /** A share of the viewer's own: opens the dialog to sell (#407). */
  onSell: (corp: string) => void;
  onPick: (corp: string, key: string) => void;
  onTab: (tab: Tab) => void;
  /** A Kurstafel cell with corporations on it: opens the list of them (#484). */
  onCell?: (row: number, col: number) => void;
  /** Dialog: cancel, Escape and the backdrop only drop the choice; the main button sends. */
  onClose?: () => void;
  onConfirm?: () => void;
  /** A kind of the action row (#527): the frame takes the choice (the same kind again goes back to step 1). */
  onKind?: (kind: Kind) => void;
}

export interface SheetInput {
  g: Game;
  theme: Theme;
  rows: CorpRow[];
  market: MarketModel;
  focus: string | null;
  sel: Selection | null;
  tab: Tab;
  mode: Mode;
  must: MustSell | null;
  /** "row,col" of the Kurstafel cell whose corporation list is open. */
  cellList?: string | null;
  /** The kind the player is in in the action box (#497 S3), read from the frame; null in step 1: all cards and offers show. */
  kind?: Kind | null;
  /** The kinds the viewer can pick now, in the fixed order (#527); empty when it is not the viewer's turn. */
  kinds?: { kind: Kind; count: number }[];
}

const money = (n: number | null): string => (n === null ? txt("stock.unknown_value").text : formatGeld(n));
const percent = (n: number): string => (n > 0 ? fillText("stock.pct", { n }) : txt("stock.none").text);

const sealOf = (g: Game, theme: Theme, id: string, name?: string, size: "s" | "m" = "s") =>
  Siegel({ sym: id, name, color: corpColor(theme, g, id) }, { theme, size });

export function offerLabel(o: Offer, row: CorpRow): string {
  if (o.kind === "buy") return fillText("stock.offer_buy", { pct: o.percent, source: txt(`stock.source_${o.source === "market" ? "market" : "ipo"}`).text, price: money(o.price) });
  if (o.kind === "sell") return fillText("stock.offer_sell", { pct: o.percent, price: money(o.price) });
  return fillText(row.tier === "minor" ? "stock.offer_par_minor" : "stock.offer_par", { par: formatGeld(o.price), cost: money(o.cost) });
}

function offerButton(o: Offer, row: CorpRow, sel: Selection | null, h: SheetHandlers): VNode {
  const selected = sel?.corp === row.id && sel.key === o.key;
  return v("button", {
    type: "button", class: "stock-offer", "data-kind": o.kind, "data-key": o.key, "aria-pressed": String(selected),
    onclick: () => h.onPick(row.id, o.key),
  }, offerLabel(o, row));
}

function group(headKey: string, kind: Offer["kind"], list: (BuyOffer | SellOffer | ParOffer)[], row: CorpRow, sel: Selection | null, h: SheetHandlers): VNode | null {
  if (list.length === 0) return null;
  return v("div", { class: "stock-group", "data-kind": kind },
    v("strong", {}, txt(headKey).text),
    v("div", { class: "stock-offers" }, ...list.map((o) => offerButton(o, row, sel, h))));
}

/** The share bar: one slice per holder, width = percent, in the colour of the player (pool and treasury have their own). */
function barNode(r: CorpRow, i: SheetInput): VNode {
  const label = r.holders.map((h) => `${h.name} ${h.percent} %${h.president ? ` (${txt("stock.president_mark").text})` : ""}`).join(", ");
  return v("div", { class: "stock-bar", role: "img", "aria-label": label },
    ...r.holders.map((h) => {
      const slot = h.kind === "player" ? playerSlot(h.seat) : null;
      const style = slot ? `width:${h.percent}%;--seg:var(--player-${slot});--seg-ink:${inkFor(i.theme.player[slot], i.theme)}` : `width:${h.percent}%`;
      return v("span", { class: "stock-seg", "data-kind": h.kind, "data-president": h.president ? "true" : "false", style },
        h.president ? txt("stock.president_mark").text : null, h.percent >= 20 ? String(h.percent) : null);
    }));
}

function holdersNode(r: CorpRow): VNode {
  return v("ul", { class: "stock-holders" }, ...r.holders.map((h) => v("li", { "data-kind": h.kind, "data-president": h.president ? "true" : "false" },
    v("i", { class: "stock-swatch", style: h.kind === "player" ? `--seg:var(--player-${playerSlot(h.seat)})` : "", "data-kind": h.kind, "aria-hidden": "true" }),
    `${h.name} ${h.percent}`, h.president ? v("b", {}, ` ${txt("stock.president_mark").text}`) : null)));
}

/** One card per corporation (#303): seal, id, price, trains, share bar, holders. The card selects the corporation. */
function rowNode(r: CorpRow, i: SheetInput, h: SheetHandlers): VNode {
  const open = i.focus === r.id;
  const head = v("button", {
    type: "button", class: "stock-rowbtn", "aria-pressed": String(open), title: `${r.name} · ${txt(`tier.${r.tier}`).text} · ${txt(`stock.state_${r.state === "other" ? "open" : r.state}`).text}`, onclick: () => h.onFocus(r.id),
  },
  v("span", { class: "stock-card-top" },
    sealOf(i.g, i.theme, r.id, r.name, "s"),
    v("strong", { class: "stock-id" }, r.id),
    v("span", { class: "stock-price", "data-label": txt("stock.col_price").text }, r.price !== null ? Geld(r.price) : txt("stock.none").text),
    r.state === "open" ? v("small", { class: "muted stock-state" }, txt("stock.state_open").text) : v("small", { class: "muted stock-trains", title: txt("stock.col_trains").text }, fillText("stock.trains", { n: r.trains })),
    r.actionable ? v("span", { class: "stock-mark", "aria-hidden": "true" }, "◂") : null),
  barNode(r, i), holdersNode(r));
  return v("li", { class: "stock-row", "data-corp": r.id, "data-state": r.state, "data-focus": open ? "true" : "false", "data-actionable": r.actionable ? "true" : "false" }, head);
}

/** What can be done with the focused corporation in the open dialog: the sales, or what the tab buys (#407, #408). */
export function offersNode(i: SheetInput, h: SheetHandlers): VNode | null {
  const r = i.rows.find((x) => x.id === i.focus);
  if (!r) return null;
  const o = offersFor(r, i.tab, i.mode, i.kind ?? null);
  const any = o.buys.length + o.sells.length + o.pars.length > 0;
  return v("div", { class: "stock-detail", "data-corp": r.id },
    any ? null : v("p", { class: "muted stock-idle" }, blockedReason(i.g, r) ?? txt(i.mode === "sell" ? "stock.row_idle" : "stock.nothing_to_buy").text),
    group("stock.buy_head", "buy", o.buys, r, i.sel, h),
    group("stock.sell_head", "sell", o.sells, r, i.sel, h),
    group("stock.par_head", "par", o.pars, r, i.sel, h));
}

function listNode(i: SheetInput, h: SheetHandlers): VNode {
  // With a market kind chosen, the kind replaces the tab: the cards with an offer of it, wherever the shares are.
  const rows = isMarketKind(i.kind ?? null) ? rowsForKind(i.rows, i.kind ?? null) : i.rows.filter((r) => inTab(r, i.tab));
  return v("section", { class: "stock-list", "aria-label": txt("stock.tab_list").text },
    rows.length === 0 ? v("p", { class: "muted stock-empty" }, txt(`stock.empty_${i.tab}`).text) : v("ul", { class: "stock-rows" }, ...rows.map((r) => rowNode(r, i, h))));
}

/** The shares of the viewer, one button per corporation: it opens the sale (#407). */
function holdingsNode(i: SheetInput, h: SheetHandlers): VNode {
  const kind = i.kind ?? null;
  // Selling needs the shares of the viewer: in another market kind the list has nothing to offer and stays out of the way.
  const mine = holdings(isMarketKind(kind) && kind !== "sell" ? [] : rowsForKind(i.rows, kind));
  return v("section", { class: "stock-hold-box", "aria-label": txt("stock.hold_head").text },
    v("h3", {}, txt("stock.hold_head").text),
    mine.length === 0 ? v("p", { class: "muted" }, txt("stock.hold_none").text)
      : v("ul", { class: "stock-hold-list" }, ...mine.map((r) => v("li", {},
        v("button", {
          type: "button", class: "stock-hold", "data-corp": r.id, title: fillText("stock.hold_item", { corp: r.id, pct: r.mine }), "aria-label": fillText("stock.hold_item", { corp: r.id, pct: r.mine }),
          onclick: () => h.onSell(r.id),
        }, sealOf(i.g, i.theme, r.id, r.name), v("strong", { class: "stock-id" }, r.id),
        v("span", { class: "stock-hold-pct" }, fillText("stock.pct", { n: r.mine })),
        v("span", { class: "stock-price" }, r.price !== null ? Geld(r.price) : txt("stock.none").text))))));
}

/** The action row (#527): one button per kind of action offered, in the words of the rulebook; the chosen kind is pressed. */
export function kindRowNode(i: SheetInput, h: SheetHandlers): VNode | null {
  const kinds = i.kinds ?? [];
  if (kinds.length === 0) return null;
  return v("div", { class: "stock-actions", role: "group", "aria-label": txt("stock.actions_label").text },
    ...kinds.map((k) => v("button", {
      type: "button", class: "stock-kind", "data-kind": k.kind, title: txt(`kind.${k.kind}_tip`).text, "aria-pressed": String(i.kind === k.kind),
      onclick: () => h.onKind?.(k.kind),
    }, `${txt(`kind.${k.kind}`).text} (${k.count})`)));
}

const ARROW_GLYPH = { right: "→", down: "↓", up: "↑" } as const;

function cellNode(c: MarketCellModel, i: SheetInput, h: SheetHandlers): VNode {
  const stack = sealStack(c.corps);
  const seal = (id: string) => sealOf(i.g, i.theme, id, i.g.state.corporations.find((x) => x.id === id)?.name);
  const base = c.corps.length > 0 ? fillText("stock.cell_corps", { price: formatGeld(c.price), corps: c.corps.join(", ") }) : fillText("stock.cell", { price: formatGeld(c.price) });
  const marks = [
    c.major ? fillText("stock.cell_major", { letter: c.major }) : null,
    c.regional ? fillText("stock.cell_regional", { letter: c.regional }) : null,
    ...c.arrows.map((a) => txt(`stock.arrow_${a}`).text),
  ].filter(Boolean);
  const label = marks.length > 0 ? `${base}; ${marks.join(", ")}` : base;
  const attrs = {
    class: "stock-cell", "data-type": c.type ?? "", "data-valid": c.valid ? "true" : "false", "data-chosen": c.chosen ? "true" : "false",
    "data-preview": c.preview ? "true" : "false", "data-price": String(c.price), "aria-label": label,
    "data-major": c.major ?? "", "data-regional": c.regional ?? "", "data-arrows": c.arrows.length > 0 ? "true" : "false",
  };
  const body = [
    c.arrows.length > 0 ? v("span", { class: "stock-cell-arrows", "aria-hidden": "true" }, ...c.arrows.map((a) => v("span", { class: "stock-arrow", "data-dir": a }, ARROW_GLYPH[a]))) : null,
    v("span", { class: "stock-cell-price" }, formatGeld(c.price)),
    c.major ? v("span", { class: "stock-cell-major", "aria-hidden": "true" },
      v("span", { class: "stock-major-long" }, fillText("stock.major_label", { letter: c.major })), v("span", { class: "stock-major-short" }, c.major)) : null,
    c.regional ? v("span", { class: "stock-cell-regional", "aria-hidden": "true" }, fillText("stock.regional_label", { letter: c.regional })) : null,
    stack.shown.length > 0 ? v("span", { class: "stock-cell-corps" }, ...stack.shown.map(seal)) : null,
    stack.more > 0 ? v("span", { class: "stock-cell-more", "aria-hidden": "true" }, fillText("stock.more_seals", { n: stack.more })) : null,
  ];
  if (c.valid) {
    const row = i.rows.find((r) => r.id === i.focus);
    const offer = row?.pars.find((p) => p.cell?.row === c.row && p.cell.col === c.col);
    return v("button", { ...attrs, type: "button", "aria-pressed": String(c.chosen), onclick: () => { if (row && offer) h.onPick(row.id, offer.key); } }, ...body);
  }
  // Seals on the cell: a tap opens the list of all of them with name and price.
  if (c.corps.length > 0) return v("button", { ...attrs, type: "button", "aria-haspopup": "dialog", onclick: () => h.onCell?.(c.row, c.col) }, ...body);
  return v("div", attrs, ...body);
}

/** The list of the corporations on one Kurstafel cell: name and price each (#484). */
function cellListDialog(i: SheetInput, h: SheetHandlers): VNode | null {
  if (!i.cellList) return null;
  const [r, col] = i.cellList.split(",").map(Number);
  const c = i.market.rows[r!]?.[col!];
  if (!c || c.corps.length === 0) return null;
  return Dialog({
    id: "stock-cells", title: fillText("stock.cell_list_title", { price: formatGeld(c.price) }), onClose: h.onClose,
    body: [v("ul", { class: "stock-cell-list" }, ...c.corps.map((id) => v("li", { class: "stock-cell-list-item" },
      sealOf(i.g, i.theme, id, i.g.state.corporations.find((x) => x.id === id)?.name),
      v("strong", {}, id), v("span", { class: "muted" }, i.g.state.corporations.find((x) => x.id === id)?.name ?? ""),
      v("span", { class: "stock-price" }, formatGeld(c.price)))))],
    actions: [v("button", { type: "button", class: "kit-side-btn", onclick: () => h.onClose?.() }, txt("stock.close").text)],
  });
}

const emptyCell = () => v("div", { class: "stock-cell stock-cell-empty", "aria-hidden": "true" });

/** The rows are `display: contents` in one grid, so a short row is padded to the full width: otherwise the next row's cells fill the gap (#405). */
function gridNode(i: SheetInput, h: SheetHandlers): VNode {
  const cols = Math.max(0, ...i.market.rows.map((l) => l.length));
  return v("section", { class: "stock-grid", "aria-label": txt("stock.tab_grid").text },
    v("div", { class: "stock-grid-scroll", style: `--cols:${cols}` }, ...i.market.rows.map((line, r) =>
      v("div", { class: "stock-grid-row", "data-row": String(r) },
        ...line.map((c) => c ? cellNode(c, i, h) : emptyCell()),
        ...Array.from({ length: cols - line.length }, emptyCell)))),
    v("ul", { class: "stock-legend muted" },
      v("li", { "data-type": "par" }, txt("stock.legend_par").text),
      v("li", { "data-type": "convert_range" }, txt("stock.legend_convert").text),
      v("li", { "data-mark": "arrow" }, txt("stock.legend_arrow").text),
      v("li", { "data-mark": "valid" }, txt("stock.legend_target").text),
      v("li", { "data-mark": "preview" }, txt("stock.legend_after").text)));
}

/** Player order for the head: this round's in a stock round (seat order of the view), else the next stock round's (`meta.priority`, priority deal first; #406). */
function orderLine(g: Game): VNode | null {
  if (g.state.meta.finished) return null;
  const inStock = g.state.meta.round.type === "stock";
  const ids = inStock ? [...g.state.players].sort((a, b) => a.order - b.order).map((p) => p.id) : g.state.meta.priority;
  if (ids.length === 0) return null;
  return v("p", { class: "stock-order muted" }, `${txt(inStock ? "stock.order_now" : "stock.order_next").text}: `, ids.map((id) => playerName(g, id)).join(" → "));
}

const changesOf = (o: ReturnType<typeof orderModel>) => o.changes.map((c) => ({
  label: c.label,
  before: c.money && typeof c.before === "number" ? Geld(c.before) : String(c.before),
  after: c.money && typeof c.after === "number" ? Geld(c.after) : String(c.after),
}));

/** The centred dialog of a focused corporation (#407, #408): the offers of the mode and tab, the order once one is chosen.
 *  Closing it (Abbrechen, Escape, backdrop) only drops the choice; nothing is sent before the main button. */
export function stockDialog(i: SheetInput, h: SheetHandlers): VNode | null {
  const r = i.focus ? i.rows.find((x) => x.id === i.focus) : undefined;
  if (!r) return null;
  const picked = offerOf(i.rows, i.sel) !== null && i.sel?.corp === r.id;
  const o = orderModel(i.g, i.rows, i.sel);
  return Dialog({
    id: "stock-offer", title: `${r.id} · ${r.name}`, onClose: h.onClose,
    body: [
      offersNode(i, h),
      picked ? Auftrag({
        sentence: o.sentence, changes: changesOf(o), state: o.state, reason: o.reason, confirmLabel: o.confirmLabel, showCancel: true,
        onConfirm: () => h.onConfirm?.(), onCancel: () => h.onClose?.(),
      }) : v("p", { class: "muted stock-pick" }, txt("stock.pick_offer").text),
    ],
    actions: picked ? [] : [v("button", { type: "button", class: "kit-side-btn", onclick: () => h.onClose?.() }, txt("stock.close").text)],
  });
}

export function sheetNode(i: SheetInput, h: SheetHandlers): VNode {
  const me = i.g.state.players.find((p) => p.id === i.g.viewer);
  const p = i.g.state.prompt;
  const status = i.g.state.meta.finished ? null
    : p.viewer_to_act && p.step === "BuySellParShares" ? txt("stock.status_mine").text
      : fillText("stock.status_other", { names: i.g.state.meta.active_players.map((id) => playerName(i.g, id)).join(", ") });
  const sheet = v("div", { class: "stock-sheet", "data-tab": i.tab },
    v("header", { class: "stock-head" },
      status ? v("p", { class: "stock-status", role: "status" }, status) : v("h2", {}, txt("stock.title").text),
      kindRowNode(i, h),
      v("div", { class: "stock-tabs", role: "tablist" },
        ...(["stock", "market"] as const).map((t) => v("button", { type: "button", role: "tab", "data-tab": t, "aria-selected": String(i.tab === t), onclick: () => h.onTab(t) }, txt(`stock.tab_${t}`).text))),
      orderLine(i.g),
      me ? v("span", { class: "stock-cash" }, `${txt("stock.cash").text} `, Geld(me.cash), ` · ${txt("stock.certs").text} ${fillText("stock.certs_of", { n: me.certs, limit: me.cert_limit })}`) : null),
    i.must ? v("p", { class: "stock-warn", role: "alert" }, fillText("stock.must_sell", { limit: i.must.limit, certs: i.must.certs })) : null,
    v("div", { class: "stock-body" }, listNode(i, h), holdingsNode(i, h), gridNode(i, h)));
  return v("div", { class: "stock-stage" }, sheet, stockDialog(i, h) ?? cellListDialog(i, h));
}
