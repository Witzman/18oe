// Endstand-Tafel (#176, ui-spec 4.8, view X1): ranking, winner, value breakdown per player (cash, share value,
// privates), corporation overview. Pure model (`endgameModel`) plus the VNode panel (`Endstand`); the frame
// mounts it above the main area once `meta.finished` is set. All text from text.ts, colours from tokens.
import type { Theme } from "../../themes/schema.ts";
import type { Game } from "../../types.ts";
import { Geld, Siegel, Tabelle, v, Wimpel, type Column, type VNode } from "../kit/index.ts";
import { fillText, txt } from "../text.ts";

export interface Holding { corp: string; percent: number; president: boolean }
export interface OwnedPrivate { id: string; name: string; value: number; faceDown: boolean }
export interface EndRow {
  rank: number; id: string; seat: number; name: string; me: boolean; winner: boolean;
  cash: number; shares: number; privates: number;
  /** meta.standings value: the number the game ranks by. */
  total: number;
  holdings: Holding[]; companies: OwnedPrivate[];
}
export interface EndCorp { id: string; name: string; type: string; president: string | null; price: number | null; cash: number; trains: number }
export interface EndModel {
  rows: EndRow[];
  winner: string | null;
  /** ASSUMPTION (#126 not delivered yet): the bank is broken when its cash is not positive. */
  bankBroken: boolean;
  bank: number;
  corps: EndCorp[];
}

export function endgameModel(g: Game): EndModel {
  const { meta, players, corporations, bank } = g.state;
  const byId = new Map(players.map((p, i) => [p.id, { p, seat: i + 1 }]));
  const standings = meta.standings.filter((s) => byId.has(s.player));
  // Players the standings do not name (should not happen) follow in seat order.
  const missing = players.filter((p) => !standings.some((s) => s.player === p.id)).map((p) => ({ player: p.id, value: p.value }));
  let rank = 0;
  let prev: number | null = null;
  const rows = [...standings, ...missing].map((s, i): EndRow => {
    const { p, seat } = byId.get(s.player)!;
    if (prev === null || s.value !== prev) rank = i + 1;
    prev = s.value;
    const companies = p.companies.map((c) => ({ id: c.id, name: c.name ?? c.id, value: c.value ?? 0, faceDown: c.face_down }));
    const privates = companies.filter((c) => !c.faceDown).reduce((n, c) => n + c.value, 0);
    return {
      rank, id: p.id, seat, name: p.name, me: p.id === g.viewer, winner: meta.winner === p.id,
      cash: p.cash, privates, total: s.value,
      // The view has no value per share certificate, so the share value is the remainder of the final value
      // (final value = cash + shares + open privates, engine player_value); see issue "Anteilswert je Firma".
      shares: s.value - p.cash - privates,
      holdings: p.shares.map((x) => ({ corp: x.corporation, percent: x.percent, president: x.president })), companies,
    };
  });
  return {
    rows, winner: meta.winner, bank: bank.cash, bankBroken: bank.cash <= 0,
    corps: corporations.filter((c) => c.floated && !c.closed).map((c) => ({
      id: c.id, name: c.name, type: c.type, president: c.president, price: c.share_price, cash: c.cash, trains: c.trains.length,
    })),
  };
}

export interface EndHandlers {
  theme: Theme;
  corpColor: (id: string) => string;
  open: boolean;
  onToggle: () => void;
  onMap: () => void;
  onLog: () => void;
}

const nameOf = (m: EndModel, id: string) => m.rows.find((r) => r.id === id)?.name ?? id;

export function Endstand(m: EndModel, h: EndHandlers): VNode {
  const winner = m.rows.find((r) => r.winner);
  const title = v("h2", {}, txt("end.title").de);
  if (!h.open) {
    return v("section", { class: "frame-end", "data-open": "false", "aria-label": txt("end.title").de },
      title,
      winner ? v("span", { class: "frame-end-winner" }, fillText("end.winner", { name: winner.name })) : null,
      v("button", { type: "button", class: "frame-end-show", onclick: h.onToggle }, txt("end.show").de));
  }
  const cols: Column<EndRow>[] = [
    { key: "rank", label: txt("end.rank").de, align: "right", cell: (r) => v("span", { class: "frame-end-rank" }, `${r.rank}.`) },
    { key: "player", label: txt("end.player").de, cell: (r) => v("span", { class: "frame-end-name" }, Wimpel({ seat: r.seat, name: r.name }, { theme: h.theme }), r.winner ? v("span", { class: "frame-end-crown", title: txt("end.winner_mark").de }, `★ ${txt("end.winner_mark").de}`) : null, r.me ? v("span", { class: "frame-tag" }, txt("frame.you").de) : null) },
    { key: "cash", label: txt("frame.cash").de, align: "right", cell: (r) => Geld(r.cash) },
    { key: "shares", label: txt("frame.shares").de, align: "right", cell: (r) => Geld(r.shares) },
    { key: "privates", label: txt("frame.companies").de, align: "right", cell: (r) => Geld(r.privates) },
    { key: "total", label: txt("end.total").de, align: "right", cell: (r) => v("strong", {}, Geld(r.total)) },
  ];
  const table = Tabelle(cols, m.rows, { caption: txt("end.ranking").de, rowState: (r) => (r.winner ? "selected" : "normal") });
  const cards = m.rows.map((r) => v("article", { class: "frame-end-card", "data-winner": r.winner ? "true" : "false" },
    v("h3", {}, `${r.rank}. ${r.name}`),
    v("dl", { class: "frame-detail" },
      v("dt", {}, txt("frame.cash").de), v("dd", {}, Geld(r.cash)),
      v("dt", {}, txt("frame.shares").de),
      v("dd", { class: "frame-end-holdings" },
        ...(r.holdings.length === 0 ? [txt("frame.none").de] : r.holdings.map((x) => v("span", { class: "frame-end-holding" },
          Siegel({ sym: x.corp, color: h.corpColor(x.corp) }, { theme: h.theme, size: "s" }), `${x.percent}%${x.president ? " ★" : ""}`))),
        v("span", { class: "frame-end-sub" }, Geld(r.shares))),
      v("dt", {}, txt("frame.companies").de),
      v("dd", {}, r.companies.length === 0 ? txt("frame.none").de : v("ul", { class: "frame-end-privates" },
        ...r.companies.map((c) => v("li", { class: c.faceDown ? "muted" : "" }, c.name, " ", c.faceDown ? txt("end.face_down").de : Geld(c.value)))),
        v("span", { class: "frame-end-sub" }, Geld(r.privates))))));
  const corpCols: Column<EndCorp>[] = [
    { key: "corp", label: txt("frame.corps").de, cell: (c) => v("span", {}, Siegel({ sym: c.id, name: c.name, color: h.corpColor(c.id) }, { theme: h.theme, size: "s" }), ` ${c.name}`) },
    { key: "president", label: txt("frame.president").de, cell: (c) => (c.president ? nameOf(m, c.president) : txt("frame.none").de) },
    { key: "price", label: txt("frame.share_price").de, align: "right", cell: (c) => (c.price === null ? "—" : Geld(c.price)) },
    { key: "cash", label: txt("frame.cash").de, align: "right", cell: (c) => Geld(c.cash) },
    { key: "trains", label: txt("frame.trains").de, align: "right", cell: (c) => String(c.trains) },
  ];
  return v("section", { class: "frame-end", "data-open": "true", "aria-label": txt("end.title").de },
    v("div", { class: "frame-end-head" }, title,
      winner ? v("p", { class: "frame-end-winner" }, fillText("end.winner", { name: winner.name }), " ", Geld(winner.total)) : null,
      m.bankBroken ? v("p", { class: "muted", title: txt("end.reason_note").de }, txt("end.reason_bank").de) : null),
    v("div", { class: "frame-end-buttons" },
      v("button", { type: "button", onclick: h.onMap }, txt("end.map").de),
      v("button", { type: "button", onclick: h.onLog }, txt("frame.log").de),
      v("a", { class: "frame-end-lobby", href: "#/" }, txt("end.lobby").de)),
    table,
    v("p", { class: "muted frame-end-note" }, txt("end.shares_note").de),
    v("div", { class: "frame-end-cards" }, ...cards),
    m.corps.length > 0 ? Tabelle(corpCols, m.corps, { caption: txt("end.corps").de }) : null);
}
