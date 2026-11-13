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
import { corpRows, marketModel, mustSell, offerOf, orderModel, parCell, passAction, STOCK_STEP, STOCK_TYPES } from "../ui/panels/stock-model.ts";
import { offerLabel, sheetNode, type SheetHandlers, type SheetInput } from "../ui/panels/stock-sheet.ts";

const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/games/${n}.json`, import.meta.url), "utf8")) as Game;
const pool = load("stock-pool"), par = load("stock-par");
const theme = themes[0]!;
// The corporation the viewer can sell in the pool fixture (any: the recording is a seeded random game).
const SELL = corpRows(pool).find((r) => r.sells.length > 0)!.id;
const noop: SheetHandlers = { onFocus: () => {}, onPick: () => {}, onTab: () => {}, onMap: () => {} };
const input = (g: Game, o: Partial<SheetInput> = {}): SheetInput => {
  const rows = corpRows(g);
  return { g, theme, rows, market: marketModel(g, rows, o.focus ?? null, o.sel ?? null), focus: null, sel: null, tab: "list", must: mustSell(g), ...o };
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

test("sheet: offers of the focused row are buttons with the label of the offer; picking calls back with corporation and key", () => {
  const rows = corpRows(pool);
  const row = rows.find((r) => r.id === SELL)!;
  const picked: [string, string][] = [];
  const tree = sheetNode(input(pool, { focus: SELL }), { ...noop, onPick: (c, k) => picked.push([c, k]) });
  const offers = find(tree, (n) => n.tag === "button" && n.attrs.class === "stock-offer");
  assert.equal(offers.length, row.buys.length + row.sells.length + row.pars.length);
  for (const b of offers) assert.ok(textOf(b).length > 3);
  offers[0]!.on.click!(new Event("click"));
  assert.deepEqual(picked, [[SELL, offers[0]!.attrs["data-key"]!]]);
  assert.match(offerLabel(row.sells[0]!, row), new RegExp(`^${row.sells[0]!.percent} % verkaufen, £${row.sells[0]!.price}$`));
});

test("sheet: every row opens by a real button; the rows of the whole list are all present; the grid has a cell per market field", () => {
  const rows = corpRows(pool);
  const tree = sheetNode(input(pool), noop);
  const heads = find(tree, (n) => n.tag === "button" && n.attrs.class === "stock-rowbtn");
  assert.equal(heads.length, rows.length);
  const cells = find(tree, (n) => n.attrs.class === "stock-cell");
  assert.equal(cells.length, pool.state.market.rows.flat().filter(Boolean).length);
  // Seals sit on the cells of their corporations.
  const seals = find(tree, (n) => n.attrs.class?.includes("kit-seal") === true && (n.attrs.class ?? "").length > 0);
  assert.ok(seals.length > 0);
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
