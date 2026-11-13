// Train purchase panel (#175): the pure model on a recorded real state (buy-train = corporation B must buy
// its first train; buy-train-reserved = the same with the view's `context.train` and a second, foreign train).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { Game } from "../types.ts";
import { createClaims } from "../ui/frame/claims.ts";
import { genericModel } from "../ui/frame/generic.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { TrainPanel, dutyLine, effectiveSelection, emptySelection, insolvencyLines, orderFor, sentenceFor, trainRows } from "../ui/panels/train.ts";

const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/games/${n}.json`, import.meta.url), "utf8")) as Game;
const noop = { onTrain: () => {}, onPrice: () => {} };

test("rows: the reserved 2+2 comes first with the mark; the foreign train is invalid with the reason", () => {
  const rows = trainRows(load("buy-train-reserved"));
  assert.deepEqual(rows.map((r) => r.id), ["2+2-0", "2+2-3"]);
  assert.ok(rows[0]!.reserved && rows[0]!.options.length === 1 && rows[0]!.reason === null);
  assert.ok(!rows[1]!.reserved && rows[1]!.options.length === 0);
  assert.match(rows[1]!.reason!, /Pflichtkauf/);
  assert.equal(rows[0]!.left, 6);
});

test("rows: without the obligation the reasons are cash, limit or generic", () => {
  const g = load("buy-train-reserved");
  g.state.prompt.context.train!.obligation.active = false;
  const foreign = trainRows(g)[1]!;
  assert.equal(foreign.reason, "Jetzt nicht möglich", "affordable with the president, nothing else known");
  g.state.prompt.context.train!.president_may_contribute = false;
  g.state.corporations.find((c) => c.id === "B")!.cash = 10;
  assert.match(trainRows(g)[1]!.reason!, /£50 fehlen/);
  g.state.prompt.context.train!.count = 2;
  assert.match(trainRows(g)[1]!.reason!, /Zuglimit 2 in Phase 2/);
  g.state.corporations.find((c) => c.id === "B")!.cash = 500;
  g.state.prompt.context.train!.count = 0;
  assert.equal(trainRows(g)[1]!.reason, "Jetzt nicht möglich");
});

test("without the view's context (older state) the list still works, nothing is marked reserved", () => {
  const rows = trainRows(load("buy-train"));
  assert.equal(rows.length, 1);
  assert.ok(!rows[0]!.reserved && rows[0]!.options.length === 1);
});

test("the reserved 2+2 is chosen already; the sentence previews, the action is the offered one", () => {
  const g = load("buy-train-reserved");
  assert.equal(effectiveSelection(g, emptySelection()).train, "2+2-0");
  const s = sentenceFor(g, emptySelection());
  assert.match(s.text, /B kauft den Pflicht-2\+2 für £100/);
  assert.equal(s.action, g.state.prompt.actions[0]);
  // B has £80: the president (p0, £55) chips in £20 and the changes say so.
  assert.deepEqual(s.changes.map((c) => [c.label, c.before, c.after]), [["Kasse B", "£80", "£0"], ["Kasse p0", "£55", "£35"]]);
});

test("the order only exists for the viewer; main button is a preview, nothing is sent while choosing", () => {
  const g = load("buy-train-reserved");
  const sent: unknown[] = [];
  const spec = orderFor(g, emptySelection(), (a) => sent.push(a))!;
  assert.equal(spec.state, "preview");
  assert.equal(spec.confirmLabel, "Kaufen");
  assert.equal(sent.length, 0);
  spec.onConfirm();
  assert.deepEqual(sent, [g.state.prompt.actions[0]]);
  g.state.prompt.viewer_to_act = false;
  assert.equal(orderFor(g, emptySelection(), () => {}), null);
  assert.ok(trainRows(g).every((r) => r.options.length === 0 && r.reason === null), "read-only for the others");
});

test("pass becomes the side button 'Kein Zug'; without a pass action there is none", () => {
  const g = load("buy-train-reserved");
  assert.deepEqual(orderFor(g, emptySelection(), () => {})!.side, []);
  const pass = { type: "pass", entity: "B", entity_type: "corporation" };
  g.state.prompt.actions.push(pass);
  const sent: unknown[] = [];
  const side = orderFor(g, emptySelection(), (a) => sent.push(a))!.side!;
  assert.equal(side[0]!.label, "Kein Zug");
  side[0]!.onClick();
  assert.deepEqual(sent, [pass]);
});

test("several prices of a foreign train: choose train, then price; invalid until the price is chosen", () => {
  const g = load("buy-train-reserved");
  g.state.prompt.context.train!.obligation.active = false;
  g.state.prompt.actions = [40, 50, 60].map((price) => ({ type: "buy_train", entity: "B", entity_type: "corporation", train: "2+2-3", price }));
  g.state.depot.available = g.state.depot.available.filter((t) => t.id === "2+2-3");
  assert.equal(effectiveSelection(g, emptySelection()).train, "2+2-3");
  assert.equal(effectiveSelection(g, emptySelection()).price, null);
  assert.equal(orderFor(g, emptySelection(), () => {})!.state, "invalid");
  const s = sentenceFor(g, { train: "2+2-3", price: 50 });
  assert.match(s.text, /für £50 \(von A\)/);
  assert.equal(s.action!.price, 50);
  const panel = TrainPanel(g, { train: "2+2-3", price: 50 }, noop);
  assert.equal(find(panel, (n) => n.attrs.class === "train-prices").length, 1);
  assert.equal(find(panel, (n) => n.attrs.class === "train-price-btn").length, 3);
});

test("duty line: cash and missing money while the buyer has to buy", () => {
  const g = load("buy-train-reserved");
  assert.match(dutyLine(g)!, /Zugpflicht: Kasse £80, es fehlen £20/);
  g.state.prompt.context.train!.shortfall = 0;
  assert.match(dutyLine(g)!, /B muss einen Zug kaufen/);
  g.state.prompt.context.train!.must_buy = false;
  assert.equal(dutyLine(g), null);
});

test("consequence hint: first train of a kind names the new phase and the trains that rust", () => {
  const g = load("buy-train-reserved");
  g.state.depot.next = "3+3";
  g.state.depot.available = [{ ...g.state.depot.available[0]!, id: "3+3-0", name: "3+3", price: 180 }];
  g.state.depot.schedule!.push({ name: "x", count: 1, price: 1, phase_on: null, rusts_on: "3+3", obsolete_on: null, available_on: null });
  g.state.prompt.actions = [{ type: "buy_train", entity: "B", entity_type: "corporation", train: "3+3-0", price: 180 }];
  const row = trainRows(g)[0]!;
  assert.match(row.hint!, /beginnt Phase 3/);
  assert.match(row.hint!, /x rosten/);
  assert.match(sentenceFor(g, emptySelection()).warn!, /^Folge:/);
});

test("insolvency (11.6.5): lines of the latest resolution from the log tail", () => {
  const g = load("buy-train-reserved");
  assert.deepEqual(insolvencyLines(g), []);
  g.state.log.push({ action: 1400, text: "H cannot pay for its 2+2 and p1 cannot make up the difference: first-round insolvency" }, { action: 1400, text: "p1 puts all personal cash into H's treasury" }, { action: 1401, text: "other" });
  assert.equal(insolvencyLines(g).length, 2);
  assert.match(textOf(TrainPanel(g, emptySelection(), noop)), /Erstrunden-Insolvenz/);
});

test("claims: buy_train and pass leave the generic bar; sell_shares and bankrupt stay there", () => {
  const g = load("buy-train-reserved");
  g.state.prompt.actions.push({ type: "pass", entity: "B", entity_type: "corporation" }, { type: "sell_shares", entity: "p0", entity_type: "player" });
  const claims = createClaims();
  assert.equal(genericModel(g, claims).count, 3);
  claims.claim("BuyTrain", "buy_train");
  claims.claim("BuyTrain", "pass");
  assert.deepEqual(genericModel(g, claims).groups.map((x) => x.type), ["sell_shares"]);
});

test("panel: every row is a button of at least touch size class, the mark and the reason are in the text", () => {
  const text = textOf(TrainPanel(load("buy-train-reserved"), emptySelection(), noop));
  assert.match(text, /Pflichtkauf/);
  assert.match(text, /Erst der Pflichtkauf/);
  assert.match(text, /Lokomotivwerk/);
  assert.match(text, /von A/);
});
