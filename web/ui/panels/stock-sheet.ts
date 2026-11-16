// The Kursblatt as an element tree (#47, ui-spec 4.4): the share list ("Kurszettel", one row per
// corporation, the offers of the focused row as buttons) and the market grid ("Kurstafel") with the
// corporations' seals on their cells. Pure like the kit: no DOM access; tests look at the tree under node.
// Every target is a real button (at least `--shape-hit` high, no hover needed): the page works on a tablet.
import type { Theme } from "../../themes/schema.ts";
import type { Game } from "../../types.ts";
import { corpColor, playerName } from "../frame/model.ts";
import { Geld, inkFor, playerSlot, Siegel, v, Wimpel, type VNode } from "../kit/index.ts";
import { formatGeld } from "../kit/money.ts";
import { fillText, txt } from "../text.ts";
import { blockedReason, presidencies, type BuyOffer, type CorpRow, type MarketCellModel, type MarketModel, type MustSell, type Offer, type ParOffer, type SellOffer, type Selection } from "./stock-model.ts";

export type Tab = "list" | "grid";

export interface SheetHandlers {
  onFocus: (corp: string) => void;
  onPick: (corp: string, key: string) => void;
  onTab: (tab: Tab) => void;
  onMap: () => void;
}

export interface SheetInput {
  g: Game;
  theme: Theme;
  rows: CorpRow[];
  market: MarketModel;
  focus: string | null;
  sel: Selection | null;
  tab: Tab;
  must: MustSell | null;
}

const money = (n: number | null): string => (n === null ? txt("stock.unknown_value").de : formatGeld(n));
const percent = (n: number): string => (n > 0 ? fillText("stock.pct", { n }) : txt("stock.none").de);

const sealOf = (g: Game, theme: Theme, id: string, name?: string, size: "s" | "m" = "s") =>
  Siegel({ sym: id, name, color: corpColor(theme, g, id) }, { theme, size });

export function offerLabel(o: Offer, row: CorpRow): string {
  if (o.kind === "buy") return fillText("stock.offer_buy", { pct: o.percent, source: txt(`stock.source_${o.source === "market" ? "market" : "ipo"}`).de, price: money(o.price) });
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
    v("strong", {}, txt(headKey).de),
    v("div", { class: "stock-offers" }, ...list.map((o) => offerButton(o, row, sel, h))));
}

/** The share bar: one slice per holder, width = percent, in the colour of the player (pool and treasury have their own). */
function barNode(r: CorpRow, i: SheetInput): VNode {
  const label = r.holders.map((h) => `${h.name} ${h.percent} %${h.president ? ` (${txt("stock.president_mark").de})` : ""}`).join(", ");
  return v("div", { class: "stock-bar", role: "img", "aria-label": label },
    ...r.holders.map((h) => {
      const slot = h.kind === "player" ? playerSlot(h.seat) : null;
      const style = slot ? `width:${h.percent}%;--seg:var(--player-${slot});--seg-ink:${inkFor(i.theme.player[slot], i.theme)}` : `width:${h.percent}%`;
      return v("span", { class: "stock-seg", "data-kind": h.kind, "data-president": h.president ? "true" : "false", style },
        h.president ? txt("stock.president_mark").de : null, h.percent >= 20 ? String(h.percent) : null);
    }));
}

function holdersNode(r: CorpRow): VNode {
  return v("ul", { class: "stock-holders" }, ...r.holders.map((h) => v("li", { "data-kind": h.kind, "data-president": h.president ? "true" : "false" },
    v("i", { class: "stock-swatch", style: h.kind === "player" ? `--seg:var(--player-${playerSlot(h.seat)})` : "", "data-kind": h.kind, "aria-hidden": "true" }),
    `${h.name} ${h.percent}`, h.president ? v("b", {}, ` ${txt("stock.president_mark").de}`) : null)));
}

/** One card per corporation (#303): seal, id, price, trains, share bar, holders. The card selects the corporation. */
function rowNode(r: CorpRow, i: SheetInput, h: SheetHandlers): VNode {
  const open = i.focus === r.id;
  const head = v("button", {
    type: "button", class: "stock-rowbtn", "aria-pressed": String(open), title: `${r.name} · ${txt(`tier.${r.tier}`).de} · ${txt(`stock.state_${r.state === "other" ? "open" : r.state}`).de}`, onclick: () => h.onFocus(r.id),
  },
  v("span", { class: "stock-card-top" },
    sealOf(i.g, i.theme, r.id, r.name, "s"),
    v("strong", { class: "stock-id" }, r.id),
    v("span", { class: "stock-price", "data-label": txt("stock.col_price").de }, r.price !== null ? Geld(r.price) : txt("stock.none").de),
    r.state === "open" ? v("small", { class: "muted stock-state" }, txt("stock.state_open").de) : v("small", { class: "muted stock-trains", title: txt("stock.col_trains").de }, fillText("stock.trains", { n: r.trains })),
    r.actionable ? v("span", { class: "stock-mark", "aria-hidden": "true" }, "◂") : null),
  barNode(r, i), holdersNode(r));
  return v("li", { class: "stock-row", "data-corp": r.id, "data-state": r.state, "data-focus": open ? "true" : "false", "data-actionable": r.actionable ? "true" : "false" }, head);
}

/** What can be done with the focused corporation: the offers as buttons, for the action panel (#303). */
export function offersNode(i: SheetInput, h: SheetHandlers): VNode | null {
  const r = i.rows.find((x) => x.id === i.focus);
  if (!r) return i.g.state.prompt.step === "BuySellParShares" && i.g.state.prompt.viewer_to_act ? v("p", { class: "muted stock-pick" }, txt("stock.pick_corp").de) : null;
  return v("div", { class: "stock-detail", "data-corp": r.id },
    v("div", { class: "stock-detail-head" }, sealOf(i.g, i.theme, r.id, r.name, "s"), v("strong", {}, `${r.id} `), v("small", { class: "muted" }, r.name)),
    r.actionable ? null : v("p", { class: "muted stock-idle" }, blockedReason(i.g, r) ?? txt("stock.row_idle").de),
    group("stock.buy_head", "buy", r.buys, r, i.sel, h),
    group("stock.sell_head", "sell", r.sells, r, i.sel, h),
    group("stock.par_head", "par", r.pars, r, i.sel, h));
}

function listNode(i: SheetInput, h: SheetHandlers): VNode {
  return v("section", { class: "stock-list", "aria-label": txt("stock.tab_list").de },
    v("ul", { class: "stock-rows" }, ...i.rows.map((r) => rowNode(r, i, h))));
}

/** The presidencies of every player, in seat order (#303). */
function presNode(i: SheetInput): VNode {
  return v("section", { class: "stock-pres", "aria-label": txt("stock.pres_head").de },
    v("h3", {}, txt("stock.pres_head").de),
    v("ul", { class: "stock-pres-list" }, ...presidencies(i.g).map((p) => v("li", { class: "stock-pres-item", "data-me": p.me ? "true" : "false" },
      Wimpel({ seat: p.seat, name: p.name }, { theme: i.theme }),
      v("span", { class: "stock-pres-corps" }, ...(p.corps.length === 0 ? [v("small", { class: "muted" }, txt("stock.pres_none").de)] : p.corps.map((c) => sealOf(i.g, i.theme, c.id, c.name)))),
      v("small", { class: "muted stock-pres-n" }, String(p.corps.length))))));
}

function cellNode(c: MarketCellModel, i: SheetInput, h: SheetHandlers): VNode {
  const corps = c.corps.map((id) => sealOf(i.g, i.theme, id, i.g.state.corporations.find((x) => x.id === id)?.name));
  const label = c.corps.length > 0 ? fillText("stock.cell_corps", { price: formatGeld(c.price), corps: c.corps.join(", ") }) : fillText("stock.cell", { price: formatGeld(c.price) });
  const attrs = {
    class: "stock-cell", "data-type": c.type ?? "", "data-valid": c.valid ? "true" : "false", "data-chosen": c.chosen ? "true" : "false",
    "data-preview": c.preview ? "true" : "false", "data-price": String(c.price), "aria-label": label,
  };
  const body = [v("span", { class: "stock-cell-price" }, formatGeld(c.price)), corps.length > 0 ? v("span", { class: "stock-cell-corps" }, ...corps) : null];
  if (!c.valid) return v("div", attrs, ...body);
  const row = i.rows.find((r) => r.id === i.focus);
  const offer = row?.pars.find((p) => p.cell?.row === c.row && p.cell.col === c.col);
  return v("button", { ...attrs, type: "button", "aria-pressed": String(c.chosen), onclick: () => { if (row && offer) h.onPick(row.id, offer.key); } }, ...body);
}

function gridNode(i: SheetInput, h: SheetHandlers): VNode {
  return v("section", { class: "stock-grid", "aria-label": txt("stock.tab_grid").de },
    v("div", { class: "stock-grid-scroll", style: `--cols:${Math.max(0, ...i.market.rows.map((l) => l.length))}` }, ...i.market.rows.map((line, r) =>
      v("div", { class: "stock-grid-row", "data-row": String(r) }, ...line.map((c) => c ? cellNode(c, i, h) : v("div", { class: "stock-cell stock-cell-empty", "aria-hidden": "true" }))))),
    v("ul", { class: "stock-legend muted" },
      v("li", { "data-type": "par" }, txt("stock.legend_par").de),
      v("li", { "data-type": "convert_range" }, txt("stock.legend_convert").de),
      v("li", { "data-mark": "valid" }, txt("stock.legend_target").de),
      v("li", { "data-mark": "preview" }, txt("stock.legend_after").de)));
}

/** Player order for the head: this round's in a stock round (seat order of the view), else the next stock round's (`meta.priority`, priority deal first; #406). */
function orderLine(g: Game): VNode | null {
  if (g.state.meta.finished) return null;
  const inStock = g.state.meta.round.type === "stock";
  const ids = inStock ? [...g.state.players].sort((a, b) => a.order - b.order).map((p) => p.id) : g.state.meta.priority;
  if (ids.length === 0) return null;
  return v("p", { class: "stock-order muted" }, `${txt(inStock ? "stock.order_now" : "stock.order_next").de}: `, ids.map((id) => playerName(g, id)).join(" → "));
}

export function sheetNode(i: SheetInput, h: SheetHandlers): VNode {
  const me = i.g.state.players.find((p) => p.id === i.g.viewer);
  const p = i.g.state.prompt;
  const status = i.g.state.meta.finished ? null
    : p.viewer_to_act && p.step === "BuySellParShares" ? txt("stock.status_mine").de
      : fillText("stock.status_other", { names: i.g.state.meta.active_players.map((id) => playerName(i.g, id)).join(", ") });
  return v("div", { class: "stock-sheet", "data-tab": i.tab },
    v("header", { class: "stock-head" },
      status ? v("p", { class: "stock-status", role: "status" }, status) : v("h2", {}, txt("stock.title").de),
      v("div", { class: "stock-tabs", role: "tablist" },
        ...(["list", "grid"] as const).map((t) => v("button", { type: "button", role: "tab", "data-tab": t, "aria-selected": String(i.tab === t), onclick: () => h.onTab(t) }, txt(`stock.tab_${t}`).de))),
      orderLine(i.g),
      me ? v("span", { class: "stock-cash" }, `${txt("stock.cash").de} `, Geld(me.cash), ` · ${txt("stock.certs").de} ${fillText("stock.certs_of", { n: me.certs, limit: me.cert_limit })}`) : null,
      v("button", { type: "button", class: "stock-map", onclick: () => h.onMap() }, txt("stock.map").de)),
    i.must ? v("p", { class: "stock-warn", role: "alert" }, fillText("stock.must_sell", { limit: i.must.limit, certs: i.must.certs })) : null,
    v("div", { class: "stock-body" }, listNode(i, h), presNode(i), gridNode(i, h)));
}
