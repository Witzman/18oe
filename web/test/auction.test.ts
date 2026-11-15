// The auction panel (#46): the pure parts under node, against states recorded from the real engine
// (test/fixtures/games/auction*.json, via Oe::View.render). The DOM and sending are in auction-browser.test.ts.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { themes } from "../themes/index.ts";
import type { Game } from "../types.ts";
import { createClaims } from "../ui/frame/claims.ts";
import { genericModel, rangeAction } from "../ui/frame/generic.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { AUCTION_STEP, modeFor, openingModel, orderModel, passAction, sheetModel } from "../ui/panels/auction-model.ts";
import { bidForm, openingNode, sheetNode } from "../ui/panels/auction-sheet.ts";

const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/games/${n}.json`, import.meta.url), "utf8")) as Game;
const start = load("auction"), bids = load("auction-bids"), minorTop = load("auction-minor-top"), open = load("auction-open");
const theme = themes[0]!;
const noop = { onSelect: () => {}, onAmount: () => {} };
const card = (g: Game, id: string) => g.state.auction!.cards.find((c) => c.id === id)!;

test("sheet: every row of the packet in order, the top row marked, a lot is choosable exactly when the server offers a bid range", () => {
  const m = sheetModel(start, null)!;
  assert.deepEqual(m.rows.map((r) => r.row), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  assert.deepEqual(m.rows.filter((r) => r.top).map((r) => r.roman), ["I"]);
  assert.equal(m.rows.flatMap((r) => r.cards).length, 32);
  for (const c of m.rows.flatMap((r) => r.cards)) {
    const offered = start.state.prompt.ranges.some((r) => r.company === c.card.id);
    assert.equal(c.state === "pick", offered, c.card.id);
  }
  assert.equal(m.cash, 1350);
  assert.deepEqual(m.toAct, ["p0"]);
});

test("sheet: sold rows stay as outlines and sold cards are gone; passes and bids show", () => {
  const m = sheetModel(bids, null)!;
  assert.equal(m.rows[0]!.cards.length, 1); // PeC sold, RSC left
  const g = { ...bids, state: { ...bids.state, auction: { ...bids.state.auction!, cards: bids.state.auction!.cards.filter((c) => c.row !== 1) , top_row: 2 } } } as Game;
  const m2 = sheetModel(g, null)!;
  assert.equal(m2.rows[0]!.sold, true);
  assert.equal(m2.rows[1]!.top, true);
  assert.deepEqual(sheetModel(load("auction-passed"), null)!.passed, ["p2"]);
  const b = card(bids, "BBBT");
  assert.deepEqual(b.bid && b.bid.price, 40);
});

test("a viewer who is not to act chooses nothing", () => {
  const g = { ...start, viewer: "p1", state: { ...start.state, prompt: { ...start.state.prompt, viewer_to_act: false, ranges: [], actions: [] } } } as Game;
  const m = sheetModel(g, null)!;
  assert.ok(m.rows.flatMap((r) => r.cards).every((c) => c.state === "idle"));
  assert.equal(orderModel(g, null).action, null);
});

test("buying a top-row private at its face value: exact action, cash before and after", () => {
  const o = orderModel(start, { id: "PeC", amount: "20" });
  assert.equal(o.state, "preview");
  assert.match(o.sentence, /Kaufen: Ponts et Chaussees für £20/);
  assert.equal(o.confirmLabel, "Kaufen £20");
  assert.deepEqual(o.changes, [{ label: "Kasse nach Zuschlag", before: 1350, after: 1330 }]);
  const range = start.state.prompt.ranges.find((r) => r.company === "PeC")!;
  assert.deepEqual(o.action, rangeAction(start, range, 20));
  assert.deepEqual(o.action, { type: "bid", entity: "p0", entity_type: "player", company: "PeC", price: 20 });
});

test("a lower-row lot is a bid in advance; the amount must be on the offered grid", () => {
  const ok = orderModel(start, { id: "BBBT", amount: "45" });
  assert.match(ok.sentence, /Gebot vormerken: Barclay, Bevan, Barclay and Tritton mit £45/);
  assert.equal(ok.confirmLabel, "Bieten £45");
  assert.equal(ok.action!.price, 45);
  for (const amount of ["", "39", "42", "1351", "abc"]) {
    const bad = orderModel(start, { id: "BBBT", amount });
    assert.equal(bad.state, "invalid", amount);
    assert.equal(bad.action, null, amount);
    assert.match(bad.reason!, /mindestens £40, höchstens £1\.350 \(deine Kasse\), in Schritten von £5/);
  }
  assert.equal(orderModel(start, null).action, null);
  assert.equal(orderModel(start, { id: "NOPE", amount: "20" }).action, null);
});

test("a top-row minor: face value buys, more starts the auction among all", () => {
  const a = card(minorTop, "A");
  assert.equal(modeFor(minorTop, a, 120), "buy");
  assert.equal(modeFor(minorTop, a, 130), "bid");
  assert.equal(orderModel(minorTop, { id: "A", amount: "120" }).confirmLabel, "Kaufen £120");
  const o = orderModel(minorTop, { id: "A", amount: "130" });
  assert.equal(o.confirmLabel, "Bieten £130");
  assert.match(o.sentence, /^Bieten: /);
  assert.equal(o.action!.price, 130);
  // The step offers a bid on the later rows too, never the same as a purchase.
  assert.equal(modeFor(minorTop, card(minorTop, "D"), 120), "bid");
});

test("running auction: only the lot at auction can be bid on, with its range; the others say why not", () => {
  const m = sheetModel(open, null)!;
  assert.equal(m.running!.card.id, "A");
  assert.deepEqual(m.running!.high && m.running!.high.price, 130);
  const picks = m.rows.flatMap((r) => r.cards).filter((c) => c.state === "pick");
  assert.deepEqual(picks.map((c) => c.card.id), ["A"]);
  const blocked = m.rows.flatMap((r) => r.cards).find((c) => c.card.id === "B")!;
  assert.match(blocked.why!, /Erst nach der Versteigerung um Silver Banner Line/);
  assert.equal(orderModel(open, { id: "A", amount: "135" }).confirmLabel, "Bieten £135");
  assert.equal(orderModel(open, { id: "A", amount: "1215" }).action, null); // above the offered maximum
});

test("pass is the action the server offers, unchanged", () => {
  assert.deepEqual(passAction(start), start.state.prompt.actions.find((a) => a.type === "pass"));
  assert.deepEqual(passAction(open), { type: "pass", entity: "p0", entity_type: "player" });
});

test("claims: bid and pass of the auction step leave the generic bar, the lot ranges too", () => {
  for (const g of [start, bids, open]) {
    const claims = createClaims();
    assert.ok(genericModel(g, claims).count > 0);
    claims.claim(AUCTION_STEP, "bid");
    claims.claim(AUCTION_STEP, "pass");
    assert.equal(genericModel(g, claims).count, 0);
  }
});

test("sheet tree: lots are buttons that select by id; the running lot and the amount form are shown", () => {
  const picked: string[] = [];
  const tree = sheetNode(sheetModel(start, "BBBT")!, start, { id: "BBBT", amount: "40" }, theme, { ...noop, onSelect: (id) => { picked.push(id); } });
  const buttons = find(tree, (n) => n.tag === "button" && n.attrs["data-card"] !== undefined);
  assert.equal(buttons.length, 32);
  buttons.find((b) => b.attrs["data-card"] === "WS")!.on.click!(new Event("click"));
  assert.deepEqual(picked, ["WS"]);
  assert.equal(find(tree, (n) => n.attrs["data-card"] === "BBBT")[0]!.attrs["aria-pressed"], "true");
  assert.equal(find(tree, (n) => n.tag === "input").length, 1);
  assert.match(textOf(tree), /Deine Kasse/);

  const run = sheetNode(sheetModel(open, "A")!, open, { id: "A", amount: "135" }, theme, noop);
  assert.match(textOf(run), /Versteigerung um Silver Banner Line/);
  assert.match(textOf(run), /Höchstgebot £130 von p3/);
  assert.equal(find(run, (n) => n.attrs["data-running"] === "true").length, 1);
});

test("amount form: a fixed price has no field; a bad amount is marked and named", () => {
  assert.equal(find(bidForm(start, { id: "PeC", amount: "20" }, noop)!, (n) => n.tag === "input").length, 0);
  const f = bidForm(start, { id: "BBBT", amount: "41" }, noop)!;
  const input = find(f, (n) => n.tag === "input")[0]!;
  assert.equal(input.attrs["aria-invalid"], "true");
  assert.equal(input.attrs.min, "40"); assert.equal(input.attrs.max, "1350"); assert.equal(input.attrs.step, "5");
  let got = "";
  bidForm(start, { id: "BBBT", amount: "40" }, { ...noop, onAmount: (v) => { got = v; } });
  assert.match(textOf(bidForm(start, null, noop)!), /Wähle ein Los/); // my turn: the region stays, so the board does not jump
  const idle = { ...start, state: { ...start.state, prompt: { ...start.state.prompt, viewer_to_act: false } } } as Game;
  assert.equal(bidForm(idle, null, noop), null);
  assert.equal(got, "");
});

test("Eröffnung: who owns what, kind from the id", () => {
  const rows = openingModel(bids);
  assert.equal(rows.length, 4);
  const p0 = rows.find((r) => r.player === "p0")!;
  assert.deepEqual(p0.items.map((i) => [i.id, i.kind]), [["PeC", "private"]]);
  assert.match(textOf(openingNode(rows, theme)), /Ponts et Chaussees/);
  assert.match(textOf(openingNode(openingModel(start), theme)), /noch nichts gekauft/);
});

// ---- #256: ability text from the catalog, home line of the minor lots ----
import type { Catalog } from "../types.ts";
import { abilityText, firstSentence } from "../ui/panels/auction-model.ts";
import { createApi } from "../api.ts";

const cat = {
  schema: 1,
  privates: [{ id: "PeC", name: "Ponts", value: 20, revenue: 5, text: "Closes in phase 3. Pays double.", auction_row: 1, abilities: [] }],
  concessions: [{ id: "CON1", name: "Conc", value: 0, revenue: 0, text: "Concession for a regional.", auction_row: 9, abilities: [] }],
  minors: [
    { id: "A", name: "Minor A", color: "#fff", text_color: null, token_prices: [], text: "Runs a ferry. Extra token.", charter: { id: "A", name: "A", value: 0, revenue: 0, text: "Charter text.", auction_row: 5, abilities: [] } },
    { id: "B", name: "Minor B", color: "#fff", text_color: null, token_prices: [], text: "", charter: { id: "B", name: "B", value: 0, revenue: 0, text: "Charter of B.", auction_row: 5, abilities: [] } },
  ],
  regionals: [],
} as Catalog;

test("abilityText: private and concession by id, minor own text with charter as fallback, nothing without catalog", () => {
  assert.equal(abilityText(cat, card(start, "PeC")), "Closes in phase 3. Pays double.");
  assert.equal(abilityText(cat, card(start, "CON1")), "Concession for a regional.");
  assert.equal(abilityText(cat, card(start, "A")), "Runs a ferry. Extra token.");
  assert.equal(abilityText(cat, card(start, "B")), "Charter of B.");
  assert.equal(abilityText(cat, card(start, "WS")), null);
  assert.equal(abilityText(null, card(start, "PeC")), null);
});

test("firstSentence: up to the first stop, whole text when there is none", () => {
  assert.equal(firstSentence("Closes in phase 3. Pays double."), "Closes in phase 3.");
  assert.equal(firstSentence("No stop here"), "No stop here");
  assert.equal(firstSentence("Costs 1.5 times. Next."), "Costs 1.5 times.");
});

test("sheet: lots carry text and short line; minors list the free zones, others no home", () => {
  const m = sheetModel(start, null, cat)!;
  const cards = m.rows.flatMap((r) => r.cards);
  const pec = cards.find((c) => c.card.id === "PeC")!, a = cards.find((c) => c.card.id === "A")!;
  assert.equal(pec.short, "Closes in phase 3.");
  assert.equal(pec.home, null);
  assert.deepEqual(a.home, start.state.zones.filter((z) => z.free).map((z) => ({ zone: z.id, price: z.price })));
  assert.ok(a.home!.length > 0);
  assert.equal(sheetModel(start, null)!.rows[0]!.cards[0]!.text, null);
});

test("sheet node: short line and home line stay visible on the card, the tooltip carries the full text", () => {
  const m = sheetModel(start, null, cat)!;
  const node = sheetNode(m, start, null, theme, noop);
  const pec = find(node, (n) => n.attrs["data-card"] === "PeC")[0]!;
  assert.match(textOf(pec), /Closes in phase 3\./);
  const a = find(node, (n) => n.attrs["data-card"] === "A")[0]!;
  assert.match(textOf(a), /Heimat frei wählbar/);
  assert.match(textOf(a), /£\d+/);
  const tips = find(node, (n) => n.attrs.class === "kit-tip-text" && textOf(n).includes("Pays double"));
  assert.equal(tips.length, 1);
});

test("api.catalog: one request, cached; a failure is retried", async () => {
  let calls = 0;
  const api = createApi(async () => { calls++; return new Response(JSON.stringify(cat), { status: 200, headers: { "Content-Type": "application/json" } }); });
  await api.catalog(); await api.catalog();
  assert.equal(calls, 1);
  let n = 0;
  const flaky = createApi(async () => { n++; return n === 1 ? new Response("{}", { status: 500 }) : new Response(JSON.stringify(cat), { status: 200 }); });
  await assert.rejects(flaky.catalog());
  assert.equal((await flaky.catalog()).schema, 1);
});
