// The stock sheet (#47): the pure parts under node, against states recorded from the real engine
// (test/fixtures/games/stock-*.json, via Oe::View.render). The DOM and sending are in stock-browser.test.ts.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { themes } from "../themes/index.ts";
import type { Game } from "../types.ts";
import { createClaims } from "../ui/frame/claims.ts";
import { genericModel } from "../ui/frame/generic.ts";
import { kindOfAction, type Kind } from "../ui/frame/kinds.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { corpRows, parTableModel, holdings, inTab, marketModel, offerKind, offersOfKind, rowsForKind, sealStack, mustSell, offersFor, offerOf, orderModel, parCell, passAction, STOCK_STEP, STOCK_TYPES } from "../ui/panels/stock-model.ts";
import { kindOptionsNode, offerLabel, offersNode, sheetNode, type SheetHandlers, type SheetInput } from "../ui/panels/stock-sheet.ts";

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

// ---- Kurstafel as the board (#478): arrows at the edges, MAJOR A to F, regional par letters -------------------

const cellAt = (m: ReturnType<typeof marketModel>, r: number, c: number) => m.rows[r]![c]!;

test("kurstafel: arrows follow the edge of the staircase (up blocked -> right, left blocked -> down, right blocked -> up)", () => {
  const m = marketModel(pool, corpRows(pool), null, null);
  const rows = m.rows;
  // Top row: every cell with a right neighbour points right; the last one (550) has none.
  const top = rows[0]!.map((c, i) => (c ? { c, i } : null)).filter(Boolean) as { c: NonNullable<(typeof rows)[0][0]>; i: number }[];
  assert.ok(top.slice(0, -1).every((x) => x.c.arrows.includes("right")), "top row points right");
  assert.deepEqual(top[top.length - 1]!.c.arrows, []);
  // The first cell of the top row (110) also has nothing to its left: down.
  assert.deepEqual(top[0]!.c.arrows, ["right", "down"]);
  // The last cell of every lower row points up; the last cell of a row that is not the top one never points right.
  rows.slice(1).forEach((line, i) => {
    const last = [...line].reverse().find(Boolean)!;
    assert.ok(last.arrows.includes("up"), `row ${i + 1} ends in an up arrow`);
    assert.ok(!last.arrows.includes("right"));
  });
  // A cell with neighbours on both sides and a cell above carries no arrow.
  assert.deepEqual(cellAt(m, 2, 3).arrows, []);
});

test("kurstafel: the six major par cells are labelled MAJOR A to F from the cheapest, the regional pars A to F likewise", () => {
  const m = marketModel(pool, corpRows(pool), null, null);
  const flat = m.rows.flat().filter(Boolean) as NonNullable<(typeof m.rows)[0][0]>[];
  const majors = flat.filter((c) => c.type === "convert_range").sort((a, b) => a.price - b.price);
  assert.deepEqual(majors.map((c) => [c.price, c.major]), [[75, "A"], [80, "B"], [90, "C"], [100, "D"], [110, "E"], [120, "F"]]);
  assert.ok(flat.filter((c) => c.type !== "convert_range").every((c) => c.major === null));
  const regs = flat.filter((c) => c.type === "par").sort((a, b) => a.price - b.price);
  assert.deepEqual(regs.map((c) => [c.price, c.regional]), [[60, "A"], [65, "B"], [70, "C"], [75, "D"], [80, "E"], [90, "F"]]);
});

test("kurstafel: the cell says what its arrows and its par mark mean in words (colour is not the only carrier)", () => {
  const tree = sheetNode(input(pool), noop);
  const cells = find(tree, (n) => n.attrs.class === "stock-cell");
  const labels = cells.map((n) => String(n.attrs["aria-label"]));
  assert.ok(labels.some((l) => /Major-Par A/.test(l)), "major par named");
  assert.ok(labels.some((l) => /Regional-Par A/.test(l)), "regional par named");
  assert.ok(labels.some((l) => /nach rechts/.test(l)) && labels.some((l) => /nach unten/.test(l)) && labels.some((l) => /nach oben/.test(l)), "arrows named");
  // The arrows sit in a strip that is hidden from screen readers (the aria-label above says it in words).
  const strips = find(tree, (n) => n.attrs.class === "stock-cell-arrows");
  assert.ok(strips.length > 0 && strips.every((n) => n.attrs["aria-hidden"] === "true"));
  assert.ok(find(tree, (n) => n.attrs.class === "stock-cell-major").length === 6);
});

// ---- Kurstafel against the printed board (#484): staircase, seal stack, label fallback ----------------------------

/** The board image, row by row: [first column, [price, arrows] of the cells that carry an arrow]. Columns are the engine's (the red MAJOR column is 4). */
const BOARD: { row: number; first: number; len: number; down: number; right: number[]; up: number | null }[] = [
  { row: 0, first: 3, len: 16, down: 3, right: Array.from({ length: 15 }, (_, i) => 3 + i), up: null },
  { row: 1, first: 2, len: 17, down: 2, right: [2], up: 18 },
  { row: 2, first: 1, len: 15, down: 1, right: [1], up: 15 },
  { row: 3, first: 0, len: 13, down: 0, right: [0], up: 12 },
  { row: 4, first: 0, len: 11, down: 0, right: [], up: 10 },
  { row: 5, first: 0, len: 9, down: 0, right: [], up: 8 },
  { row: 6, first: 0, len: 7, down: 0, right: [], up: 6 },
  { row: 7, first: 0, len: 6, down: 0, right: [], up: 5 },
  { row: 8, first: 0, len: 5, down: 0, right: [], up: 4 },
];

test("kurstafel: the nine-row grid has the board's staircase, MAJOR column and arrows cell by cell (#484)", () => {
  const m = marketModel(pool, corpRows(pool), null, null);
  assert.equal(m.rows.length, 9);
  for (const b of BOARD) {
    const line = m.rows[b.row]!;
    const filled = line.map((c, i) => (c ? i : -1)).filter((i) => i >= 0);
    assert.equal(filled[0], b.first, `row ${b.row} starts at column ${b.first}`);
    assert.equal(filled.length, b.len, `row ${b.row} length`);
    line.forEach((c, i) => {
      if (!c) return;
      const want = [b.right.includes(i) ? "right" : null, i === b.down ? "down" : null, i === b.up ? "up" : null].filter(Boolean);
      assert.deepEqual([...c.arrows].sort(), want.sort(), `row ${b.row} col ${i} (${c.price})`);
    });
  }
  // The red MAJOR column: column 4 in rows 0 to 5 (A at 75 .. F at 120), nowhere else.
  m.rows.forEach((line, r) => line.forEach((c, i) => { if (c) assert.equal(c.major !== null, i === 4 && r <= 5, `major at ${r},${i}`); }));
  assert.deepEqual(m.rows[8]!.filter(Boolean).map((c) => c!.price), [30, 40, 50, 55, 60]);
});

test("kurstafel: a cell's seals: up to three show, more become a counter; every corporation stays in the list (#484)", () => {
  assert.deepEqual(sealStack(["A", "B"]), { shown: ["A", "B"], more: 0 });
  assert.deepEqual(sealStack(["A", "B", "C"]), { shown: ["A", "B", "C"], more: 0 });
  assert.deepEqual(sealStack(["A", "B", "C", "D", "E"]), { shown: ["A", "B", "C"], more: 2 });
  assert.deepEqual(sealStack([]), { shown: [], more: 0 });
});

test("kurstafel: a cell with several corporations is a button that opens a list with name and price; Escape keys come from the dialog (#484)", () => {
  const m = marketModel(pool, corpRows(pool), null, null);
  const cell = m.rows.flat().find((c) => c && c.corps.length > 3)!;
  const opened: string[] = [];
  const h: SheetHandlers = { ...noop, onCell: (r, c) => opened.push(`${r},${c}`) };
  const tree = sheetNode(input(pool), h);
  const btn = find(tree, (n) => n.tag === "button" && n.attrs.class === "stock-cell" && n.attrs["data-price"] === String(cell.price) && String(n.attrs["aria-label"]).includes(cell.corps[0]!))[0]!;
  assert.ok(btn, "the stacked cell is a button");
  assert.match(String(btn.attrs["aria-label"]), new RegExp(cell.corps.join(", ")));
  assert.ok(find(btn, (n) => n.attrs.class === "stock-cell-more").length === 1, "counter");
  assert.equal(find(btn, (n) => n.attrs.class === "stock-cell-corps")[0]!.children.length, 3);
  btn.on.click!(new Event("click"));
  assert.deepEqual(opened, [`${cell.row},${cell.col}`]);
  const open = sheetNode(input(pool, { cellList: `${cell.row},${cell.col}` }), h);
  const items = find(open, (n) => n.attrs.class === "stock-cell-list-item");
  assert.equal(items.length, cell.corps.length);
  const text = textOf(find(open, (n) => n.attrs.role === "dialog")[0]!);
  for (const id of cell.corps) assert.match(text, new RegExp(id));
  assert.match(text, /£\d+/);
});

test("kurstafel: the MAJOR label has a long and a short form; the legend says the letter stands for MAJOR A to F (#484)", () => {
  const tree = sheetNode(input(pool), noop);
  const majors = find(tree, (n) => n.attrs.class === "stock-cell-major");
  assert.equal(majors.length, 6);
  for (const n of majors) {
    assert.equal(find(n, (x) => x.attrs.class === "stock-major-long").length, 1);
    assert.equal(find(n, (x) => x.attrs.class === "stock-major-short").length, 1);
  }
  assert.match(textOf(find(tree, (n) => n.attrs["data-type"] === "convert_range" && n.tag === "li")[0]!), /MAJOR A bis F/);
});

test("kurstafel: arrows sit in their own strip above the price, never over it (#484)", () => {
  const tree = sheetNode(input(pool), noop);
  const strips = find(tree, (n) => n.attrs.class === "stock-cell-arrows");
  assert.ok(strips.length > 0);
  for (const s of strips) assert.ok(find(s, (n) => n.attrs.class === "stock-arrow").length >= 1);
  assert.equal(find(tree, (n) => n.attrs.class === "stock-cell-price" ).length, pool.state.market.rows.flat().filter(Boolean).length);
});

test("par step: valid par cells, the chosen one and its dialog on the nine-row grid (#484)", () => {
  const rows = corpRows(par);
  const row = rows.find((r) => r.pars.length > 0)!;
  const offer = row.pars[0]!;
  const m = marketModel(par, rows, row.id, { corp: row.id, key: offer.key });
  const flat = m.rows.flat().filter(Boolean);
  assert.equal(flat.filter((c) => c!.valid).length, row.pars.length);
  assert.deepEqual(flat.filter((c) => c!.chosen).map((c) => [c!.row, c!.col]), [[offer.cell!.row, offer.cell!.col]]);
  // The chosen par cell is where the action says, on the new grid.
  assert.equal(m.rows[offer.cell!.row]![offer.cell!.col]!.price, offer.price);
  const tree = sheetNode(input(par, { focus: row.id, sel: { corp: row.id, key: offer.key } }), noop);
  assert.equal(find(tree, (n) => n.attrs.class === "stock-cell" && n.attrs["data-valid"] === "true").length, row.pars.length);
  assert.equal(find(tree, (n) => n.attrs.class === "stock-cell" && n.attrs["data-chosen"] === "true").length, 1);
});

// ---- #497 S3: the sheet follows the kind of the action box ------------------------------------------------

test("kinds: every offer of a row falls in the kind kindOfAction gives its action (one reading, no second rule)", () => {
  for (const g of [pool, par]) {
    for (const r of corpRows(g)) {
      for (const o of [...r.buys, ...r.sells, ...r.pars]) assert.equal(offerKind(o, r), kindOfAction(g, o.action), `${r.id} ${o.key}`);
    }
  }
});

test("kinds: a market kind keeps only the cards and offers of that kind; no kind keeps all; a kind of another panel has no offer", () => {
  const rows = corpRows(pool);
  const all = rows.flatMap((r) => [...r.buys, ...r.sells, ...r.pars]).length;
  assert.equal(rowsForKind(rows, null).length, rows.length);
  const counts = (["buy", "sell", "float_regional", "float_minor"] as Kind[]).map((k) => rowsForKind(rows, k).flatMap((r) => { const o = offersOfKind(r, k); return [...o.buys, ...o.sells, ...o.pars]; }).length);
  assert.equal(counts.reduce((a, b) => a + b, 0), all, "the four market kinds together hold every offer, none twice");
  const buy = rowsForKind(rows, "buy");
  assert.ok(buy.length > 0 && buy.every((r) => r.buys.length > 0));
  assert.ok(buy.every((r) => { const o = offersFor(r, "stock", "sell", "buy"); return o.sells.length === 0 && o.pars.length === 0 && o.buys.length === r.buys.length; }), "the kind replaces mode and tab");
  const sell = rowsForKind(rows, "sell");
  assert.ok(sell.length > 0 && sell.every((r) => r.sells.length > 0));
  const none = offersFor(rows[0]!, "stock", "buy", "pass");
  assert.equal(none.buys.length + none.sells.length + none.pars.length, 0);
  assert.equal(rowsForKind(rows, "pass").length, rows.length, "a kind without options of this sheet leaves the cards alone");
  assert.deepEqual(offersFor(rows[0]!, "stock", "buy"), offersFor(rows[0]!, "stock", "buy", null));
});

test("kinds: par of a regional is float_regional, of a minor float_minor; they list only the corporations of that tier", () => {
  const rows = corpRows(par);
  for (const k of ["float_regional", "float_minor"] as Kind[]) {
    for (const r of rowsForKind(rows, k)) assert.equal(r.tier === "minor", k === "float_minor", `${r.id} under ${k}`);
  }
});

test("sheet: with a kind chosen the cards are those of the kind and the dialog shows only its offers; the head has no pass button", () => {
  const sheet = (kind: Kind | null, o: Partial<SheetInput> = {}) => sheetNode(input(pool, { kind, ...o }), noop);
  assert.equal(find(sheet(null), (n) => n.attrs["data-action"] === "pass").length, 0, "pass is a kind of the box, not a head button");
  const cards = (kind: Kind | null) => find(sheet(kind), (n) => n.attrs.class === "stock-row").map((n) => n.attrs["data-corp"]);
  assert.deepEqual(cards("buy").sort(), rowsForKind(corpRows(pool), "buy").map((r) => r.id).sort());
  const row = corpRows(pool).find((r) => r.buys.length > 0 && r.sells.length > 0);
  if (row) {
    const dlg = find(sheet("buy", { focus: row.id }), (n) => n.attrs.class === "kit-dialog")[0]!;
    assert.equal(find(dlg, (n) => n.attrs.class === "stock-offer").length, row.buys.length);
    assert.equal(find(dlg, (n) => n.attrs.class === "stock-offer" && n.attrs["data-kind"] === "sell").length, 0);
  }
});

test("box options (variant A): one button per corporation of the kind, each opens that corporation", () => {
  const rows = corpRows(pool);
  const opened: string[] = [];
  const nodes = kindOptionsNode(pool, theme, rows, "buy", (c) => opened.push(c));
  assert.deepEqual(nodes.map((n) => n.attrs["data-corp"]), rowsForKind(rows, "buy").map((r) => r.id));
  nodes[0]!.on.click!(new Event("click"));
  assert.deepEqual(opened, [nodes[0]!.attrs["data-corp"]]);
});

test("box: a provided kind is a step-1 button with its offer count, its options are the panel's, pass is a plain kind", () => {
  const claims = createClaims();
  STOCK_TYPES.forEach((t) => claims.claim(STOCK_STEP, t));
  const plain = genericModel(pool, claims);
  assert.ok(!plain.kinds!.some((b) => b.kind === "buy"), "claimed and not provided: the kind is absent");
  const provided = new Set<Kind>(["float_regional", "float_minor", "buy", "sell"]);
  const m = genericModel(pool, claims, provided);
  const buy = m.kinds!.find((b) => b.kind === "buy")!;
  assert.ok(buy.provided && buy.entries.length === 0);
  assert.equal(buy.count, pool.state.prompt.actions.filter((a) => a.type === "buy_shares").length);
  assert.equal(m.count - plain.count, m.kinds!.filter((b) => b.provided).reduce((n, b) => n + b.count, 0), "the claimed actions count in the box");
  const pass = m.kinds!.find((b) => b.kind === "pass");
  assert.ok(pass && !pass.provided && pass.entries.length === 1, "pass is not claimed any more: a generic entry of the kind pass");
});

// ---- Par Prices table (#478): the four columns of the board, from the market itself ------------------------

test("par table: Regional A-C, Regional D-F, Major A-C, Major D-F, each from the dearest letter down", () => {
  const t = parTableModel(pool, marketModel(pool, corpRows(pool), null, null));
  const view = t.columns.map((col) => col.map((f) => `${f.tier[0]}${f.letter}${f.price}`));
  assert.deepEqual(view, [["rC70", "rB65", "rA60"], ["rF90", "rE80", "rD75"], ["mC90", "mB80", "mA75"], ["mF120", "mE110", "mD100"]]);
});

test("par table: a par offered to the corporation in focus is valid, a founded corporation sits on its par price", () => {
  const rows = corpRows(par);
  const focus = rows.find((r) => r.pars.length > 0)!;
  const t = parTableModel(par, marketModel(par, rows, focus.id, null));
  const valid = t.columns.flat().filter((f) => f.valid);
  assert.ok(valid.length > 0 && valid.length <= focus.pars.length);
  assert.ok(t.columns.flat().filter((f) => f.corps.length > 0).every((f) => par.state.corporations.filter((c) => f.corps.includes(c.id)).every((c) => c.par_price === f.price)));
});

test("par table: the sheet shows twelve labelled fields in four columns", () => {
  const tree = sheetNode(input(pool), noop);
  assert.equal(find(tree, (n) => n.attrs.class === "stock-par-col").length, 4);
  const fields = find(tree, (n) => n.attrs["data-par-field"] !== undefined);
  assert.equal(fields.length, 12);
  assert.ok(fields.every((n) => /^(Regional|Major) [A-F], £?\d+/.test(String(n.attrs["aria-label"]))), "every field names tier, letter and price");
});
