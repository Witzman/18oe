// The stock sheet (#47): the pure parts under node, against states recorded from the real engine
// (test/fixtures/games/stock-*.json, via Oe::View.render). The DOM and sending are in stock-browser.test.ts.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { themes } from "../themes/index.ts";
import type { Game } from "../types.ts";
import { createClaims } from "../ui/frame/claims.ts";
import { genericModel } from "../ui/frame/generic.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { corpRows, holdings, inTab, marketModel, mustSell, offersFor, offerOf, orderModel, parCell, passAction, STOCK_STEP, STOCK_TYPES } from "../ui/panels/stock-model.ts";
import { offerLabel, offersNode, sheetNode, type SheetHandlers, type SheetInput } from "../ui/panels/stock-sheet.ts";

const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/games/${n}.json`, import.meta.url), "utf8")) as Game;
const pool = load("stock-pool"), par = load("stock-par");
const theme = themes[0]!;
// The corporation the viewer can sell in the pool fixture (any: the recording is a seeded random game).
const SELL = corpRows(pool).find((r) => r.sells.length > 0)!.id;
const noop: SheetHandlers = { onFocus: () => {}, onSell: () => {}, onPick: () => {}, onTab: () => {} };
const input = (g: Game, o: Partial<SheetInput> = {}): SheetInput => {
  const rows = corpRows(g);
  return { g, theme, rows, market: marketModel(g, rows, o.focus ?? null, o.sel ?? null), focus: null, sel: null, tab: "stock", mode: "buy", must: mustSell(g), ...o };
};

test("rows: a row per offered or running corporation, in tier order, money of every offer from the view", () => {
  const rows = corpRows(pool);
  assert.ok(rows.length > 0);
  const tiers = rows.map((r) => r.tier);
  assert.deepEqual(tiers, [...tiers].sort((a, b) => ["national", "major", "regional", "minor"].indexOf(a) - ["national", "major", "regional", "minor"].indexOf(b)));
  const buys = rows.flatMap((r) => r.buys);
  assert.equal(buys.length, pool.state.prompt.actions.filter((a) => a.type === "buy_shares").length);
  assert.ok(buys.every((b) => b.price !== null && b.price > 0), "every purchase has its price from prompt.context.stock");
  const sc = rows.find((r) => r.id === SELL)!;
  assert.ok(sc.mine > 0);
  assert.ok(sc.sells.length >= 1);
  assert.ok(sc.sells.every((s) => s.price! > 0));
  assert.equal(sc.treasury + sc.market + sc.mine <= 100, true);
});

test("rows: no action offered means no buttons; a viewer who is not to act chooses nothing", () => {
  const g = { ...pool, viewer: "B", state: { ...pool.state, prompt: { ...pool.state.prompt, viewer_to_act: false, actions: [], ranges: [], context: { ...pool.state.prompt.context, stock: null } } } } as Game;
  const rows = corpRows(g);
  assert.ok(rows.every((r) => !r.actionable && r.buys.length + r.sells.length + r.pars.length === 0));
  assert.equal(orderModel(g, rows, null).action, null);
  assert.equal(passAction(g), null);
});

test("order: a purchase names source, price, cash and certificates before and after, and sends exactly the offered action", () => {
  const rows = corpRows(pool);
  const row = rows.find((r) => r.buys.length > 0)!;
  const buy = row.buys[0]!;
  const o = orderModel(pool, rows, { corp: row.id, key: buy.key });
  assert.deepEqual(o.action, buy.action);
  assert.equal(o.state, "preview");
  assert.match(o.sentence, new RegExp(`${row.id}: ${buy.percent} %`));
  const me = pool.state.players.find((p) => p.id === pool.viewer)!;
  const cash = o.changes.find((c) => c.money)!;
  assert.deepEqual([cash.before, cash.after], [me.cash, me.cash - buy.price!]);
  const certs = o.changes.find((c) => c.label === "Zertifikate")!;
  assert.equal(certs.after, `${me.certs + 1} von ${me.cert_limit}`);
});

test("order: a sale shows the proceeds, the holding and the price movement", () => {
  const rows = corpRows(pool);
  const sell = rows.find((r) => r.id === SELL)!.sells[0]!;
  const row = rows.find((r) => r.id === SELL)!;
  const o = orderModel(pool, rows, { corp: SELL, key: sell.key });
  assert.deepEqual(o.action, sell.action);
  const me = pool.state.players.find((p) => p.id === pool.viewer)!;
  assert.equal(o.changes.find((c) => c.label === "Kasse")!.after, me.cash + sell.price!);
  const kurs = o.changes.find((c) => c.label === "Kurs");
  if (sell.newPrice !== null && sell.newPrice !== row.price) assert.deepEqual(kurs, { label: "Kurs", before: row.price, after: sell.newPrice, money: true });
  else assert.equal(kurs, undefined);
  assert.deepEqual(o.changes.find((c) => c.label === "Dein Anteil"), { label: "Dein Anteil", before: `${row.mine} %`, after: `${row.mine - sell.percent} %`, money: false });
  assert.equal(o.confirmLabel, "Verkaufen");
});

test("order: nothing chosen locks the main button with a reason", () => {
  const o = orderModel(pool, corpRows(pool), null);
  assert.equal(o.state, "invalid");
  assert.equal(o.action, null);
  assert.ok(o.reason);
});

test("par: the price of the president's share from the view, the cell from the action, targets on the market", () => {
  const rows = corpRows(par);
  const row = rows.find((r) => r.pars.length > 0)!;
  assert.ok(row.pars.every((p) => p.cost !== null && p.cell !== null));
  const offer = row.pars[0]!;
  assert.equal(offer.cost! > 0, true);
  const m = marketModel(par, rows, row.id, { corp: row.id, key: offer.key });
  const valid = m.rows.flat().filter((c) => c?.valid);
  assert.equal(valid.length, row.pars.length);
  assert.deepEqual(m.rows.flat().filter((c) => c?.chosen).map((c) => [c!.row, c!.col]), [[offer.cell!.row, offer.cell!.col]]);
  const o = orderModel(par, rows, { corp: row.id, key: offer.key });
  assert.deepEqual(o.action, offer.action);
  assert.equal(o.confirmLabel, "Gründen");
  assert.deepEqual(parCell("90,1,0"), { row: 1, col: 0 });
  assert.equal(parCell("x"), null);
});

test("market: the sale in the selection shows the price after it as a preview cell", () => {
  const rows = corpRows(pool);
  const sell = rows.find((r) => r.id === SELL)!.sells.find((s) => s.newPrice !== null) ?? rows.find((r) => r.id === SELL)!.sells[0]!;
  const m = marketModel(pool, rows, SELL, { corp: SELL, key: sell.key });
  const prev = m.rows.flat().filter((c) => c?.preview);
  assert.ok(prev.length <= 1);
  if (sell.newPrice !== null) assert.equal(prev[0]!.price, sell.newPrice);
  assert.equal(offerOf(rows, { corp: SELL, key: "nope" }), null);
});

test("must sell: no pass but selling offered shows the warning; with a pass there is none", () => {
  assert.equal(mustSell(pool), null);
  const actions = pool.state.prompt.actions.filter((a) => a.type !== "pass");
  const g = { ...pool, state: { ...pool.state, prompt: { ...pool.state.prompt, actions } } } as Game;
  assert.ok(mustSell(g));
  const tree = sheetNode(input(g), noop);
  assert.equal(find(tree, (n) => n.attrs.class === "stock-warn").length, 1);
  assert.equal(find(sheetNode(input(pool), noop), (n) => n.attrs.class === "stock-warn").length, 0);
});

test("sheet: the offers of the focused row are buttons with the label of the offer, as many as the mode and tab allow; picking calls back with corporation and key", () => {
  const rows = corpRows(pool);
  const row = rows.find((r) => r.id === SELL)!;
  const picked: [string, string][] = [];
  const sell = offersNode(input(pool, { focus: SELL, mode: "sell" }), { ...noop, onPick: (c, k) => picked.push([c, k]) })!;
  const offers = find(sell, (n) => n.tag === "button" && n.attrs.class === "stock-offer");
  assert.equal(offers.length, row.sells.length);
  assert.ok(offers.length > 0);
  for (const b of offers) assert.ok(textOf(b).length > 3);
  offers[0]!.on.click!(new Event("click"));
  assert.deepEqual(picked, [[SELL, offers[0]!.attrs["data-key"]!]]);
  assert.match(offerLabel(row.sells[0]!, row), new RegExp(`^${row.sells[0]!.percent} % verkaufen, £${row.sells[0]!.price}$`));
  // Buying: the treasury offers and par prices in "Aktienmarkt", the market's shares in "Open Market".
  for (const r of rows) {
    const stock = offersFor(r, "stock", "buy"), market = offersFor(r, "market", "buy");
    assert.ok(stock.buys.every((b) => b.source !== "market") && market.buys.every((b) => b.source === "market"), r.id);
    assert.equal(stock.buys.length + market.buys.length, r.buys.length, r.id);
    assert.deepEqual([market.pars, stock.sells, market.sells], [[], [], []]);
  }
});

test("sheet: every row opens by a real button; the rows of the whole list are all present; the grid has a cell per market field", () => {
  const rows = corpRows(pool);
  const tree = sheetNode(input(pool), noop);
  const heads = find(tree, (n) => n.tag === "button" && n.attrs.class === "stock-rowbtn");
  assert.equal(heads.length, rows.filter((r) => inTab(r, "stock")).length);
  assert.ok(heads.length > 0);
  const cells = find(tree, (n) => n.attrs.class === "stock-cell");
  assert.equal(cells.length, pool.state.market.rows.flat().filter(Boolean).length);
  // Seals sit on the cells of their corporations.
  const seals = find(tree, (n) => n.attrs.class?.includes("kit-seal") === true && (n.attrs.class ?? "").length > 0);
  assert.ok(seals.length > 0);
});

test("cards: share bar slices add up to 100, president first and marked", () => {
  const rows = corpRows(pool);
  for (const r of rows) {
    assert.equal(r.holders.reduce((n, h) => n + h.percent, 0), 100, r.id);
    if (r.presidentId) assert.ok(r.holders[0]!.president && r.holders[0]!.id === r.presidentId, r.id);
  }
  const tree = sheetNode(input(pool), noop);
  assert.equal(find(tree, (n) => n.attrs.class === "stock-bar").length, rows.filter((r) => inTab(r, "stock")).length);
});

test("holdings: the viewer's shares are listed in the sheet, one button per corporation that opens the sale (#407); the presidency box is gone", () => {
  const rows = corpRows(pool);
  const mine = holdings(rows);
  assert.ok(mine.length > 0);
  assert.ok(mine.every((r) => r.mine > 0));
  const opened: string[] = [];
  const tree = sheetNode(input(pool), { ...noop, onSell: (c) => opened.push(c) });
  assert.equal(find(tree, (n) => n.attrs.class === "stock-pres-item").length, 0);
  const buttons = find(tree, (n) => n.tag === "button" && n.attrs.class === "stock-hold");
  assert.deepEqual(buttons.map((b) => b.attrs["data-corp"]), mine.map((r) => r.id));
  buttons[0]!.on.click!(new Event("click"));
  assert.deepEqual(opened, [mine[0]!.id]);
});

test("tabs: Aktienmarkt lists what treasuries offer, Open Market what the market holds; the tabs replace the map button (#408)", () => {
  const rows = corpRows(pool);
  const heads = (tab: "stock" | "market") => find(sheetNode(input(pool, { tab }), noop), (n) => n.tag === "button" && n.attrs.class === "stock-rowbtn").length;
  assert.equal(heads("stock"), rows.filter((r) => inTab(r, "stock")).length);
  assert.equal(heads("market"), rows.filter((r) => r.market > 0).length);
  assert.ok(rows.some((r) => r.market > 0) && rows.some((r) => r.market === 0 || r.treasury === 0), "the fixture needs both kinds");
  const tree = sheetNode(input(pool), noop);
  const tabs = find(tree, (n) => n.tag === "button" && n.attrs.role === "tab");
  assert.deepEqual(tabs.map((t) => textOf(t)), ["Aktienmarkt", "Open Market"]);
  assert.equal(find(tree, (n) => n.attrs.class === "stock-map").length, 0);
});

test("dialog: a focused corporation opens a modal with its offers, the order and Abbrechen once one is chosen; nothing is open without focus (#407, #408)", () => {
  assert.equal(find(sheetNode(input(pool), noop), (n) => n.attrs.class === "kit-dialog").length, 0);
  const row = corpRows(pool).find((r) => r.id === SELL)!;
  const closed: number[] = [], confirmed: number[] = [];
  const h = { ...noop, onClose: () => closed.push(1), onConfirm: () => confirmed.push(1) };
  const open = sheetNode(input(pool, { focus: SELL, mode: "sell" }), h);
  const dlg = find(open, (n) => n.attrs.class === "kit-dialog")[0]!;
  assert.match(textOf(dlg), new RegExp(SELL));
  assert.equal(find(dlg, (n) => n.attrs.class === "stock-offer").length, row.sells.length);
  assert.equal(find(dlg, (n) => n.attrs.class?.includes("kit-main-btn") === true).length, 0, "no order before a choice");
  const chosen = sheetNode(input(pool, { focus: SELL, mode: "sell", sel: { corp: SELL, key: row.sells[0]!.key } }), h);
  const dlg2 = find(chosen, (n) => n.attrs.class === "kit-dialog")[0]!;
  assert.match(textOf(dlg2), /verkaufen/);
  const main = find(dlg2, (n) => n.attrs.class?.includes("kit-main-btn") === true)[0]!;
  main.on.click!(new Event("click"));
  assert.deepEqual(confirmed, [1]);
  assert.deepEqual(closed, []);
});

test("claims: buy, sell, par and pass of the stock step are the panel's; convert and choose stay generic", () => {
  const claims = createClaims();
  assert.ok(genericModel(pool, claims).groups.some((gr) => gr.type === "buy_shares"));
  const release = STOCK_TYPES.map((t) => claims.claim(STOCK_STEP, t));
  const types = genericModel(pool, claims).groups.map((gr) => gr.type);
  assert.ok(!types.some((t) => (STOCK_TYPES as readonly string[]).includes(t)), types.join());
  release.forEach((f) => f());
  assert.ok(genericModel(pool, claims).groups.some((gr) => gr.type === "buy_shares"));
});

test("a market offer is labelled as taken from the market", () => {
  const rows = corpRows(pool);
  const row = rows.find((r) => r.buys.length > 0)!;
  const o = { ...row.buys[0]!, source: "market" };
  assert.match(offerLabel(o, row), /aus dem Markt/);
  assert.match(offerLabel(row.buys[0]!, row), /aus dem Schatzamt/);
});

test("order: in a stock round the head names the players in this round's order; outside one, the order of the next stock round (#406)", () => {
  const names = (g: Game) => find(sheetNode(input(g), noop), (n) => n.attrs.class?.includes("stock-order") === true).map((n) => textOf(n));
  const now = [...pool.state.players].sort((a, b) => a.order - b.order).map((p) => p.name);
  const [inStock] = names(pool);
  assert.ok(inStock, "the order is shown");
  assert.match(inStock!, /Reihenfolge dieser Aktienrunde/);
  assert.ok(inStock!.indexOf(now[0]!) < inStock!.indexOf(now[1]!) && inStock!.indexOf(now[1]!) < inStock!.indexOf(now[3]!), inStock);
  const next = pool.state.meta.priority.map((id) => pool.state.players.find((p) => p.id === id)!.name);
  assert.notDeepEqual(next, now, "the fixture needs a different next order");
  const operating: Game = { ...pool, state: { ...pool.state, meta: { ...pool.state.meta, round: { ...pool.state.meta.round, type: "operating" } } } };
  const [inOperating] = names(operating);
  assert.match(inOperating!, /Reihenfolge der nächsten Aktienrunde/);
  assert.ok(inOperating!.indexOf(next[0]!) < inOperating!.indexOf(next[1]!) && inOperating!.indexOf(next[1]!) < inOperating!.indexOf(next[3]!), inOperating!);
});

test("grid: every market row fills the whole line, so a short row never takes in the cells of the next one (#405)", () => {
  const tree = sheetNode(input(pool), noop);
  const lines = find(tree, (n) => n.attrs.class === "stock-grid-row");
  const cols = Math.max(...pool.state.market.rows.map((l) => l.length));
  assert.equal(lines.length, pool.state.market.rows.length);
  assert.ok(pool.state.market.rows.some((l) => l.length < cols), "the fixture needs a short row");
  for (const l of lines) assert.equal(l.children.length, cols, `row ${l.attrs["data-row"]}`);
});
