// Operating sheet (#49): the pure model on recorded states. `operating-route` is the recorded Route step of
// corporation B; `operating-dividend` the recorded Dividend step of KSS with a view context built by hand in
// the format of lib/oe/view.rb (dividend_context), to be replaced by a recorded one.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { Game } from "../types.ts";
import { createClaims } from "../ui/frame/claims.ts";
import { choiceLabel, choiceTip, genericModel } from "../ui/frame/generic.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { chosenOption, dividendOptions, dividendOrder, headOf, ladderIndex, operator, portAuthorityOptions, pullmanOptions, runLines, runModel, runSentence } from "../ui/panels/operating-model.ts";
import { DividendPanel, OperatingPanel, RoutePanel } from "../ui/panels/operating.ts";

const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/games/${n}.json`, import.meta.url), "utf8")) as Game;
const noop = { onPick: () => {} };

test("head: the operating corporation with cash, trains and free tokens; ladder marks the step", () => {
  const g = load("operating-route");
  const h = headOf(operator(g)!);
  assert.equal(h.id, "B");
  assert.deepEqual([h.cash, h.trains, h.tokensFree, h.tokensAll], [0, ["2+2"], 1, 2]);
  assert.equal(ladderIndex(g), 2);
  assert.equal(ladderIndex(load("operating-dividend")), 3);
});

test("run: one row per train from the offered run_routes action, total and sentence", () => {
  const g = load("operating-route");
  const m = runModel(g);
  assert.equal(m.action, g.state.prompt.actions[0]);
  assert.deepEqual(m.rows, [{ train: "2+2-0", stops: "H21 – G24 – G26", revenue: 60 }]);
  assert.equal(m.total, 60);
  assert.match(runSentence(g), /B fährt 1 Zug\/Züge und erzielt £60/);
  const panel = textOf(RoutePanel(g));
  assert.match(panel, /2\+2-0/);
  assert.match(panel, /Summe/);
});

test("run: Orient Express bonus and subsidy count into the total and get a row", () => {
  const g = load("operating-route");
  (g.state.prompt.actions[0] as Record<string, unknown>).extra_revenue = 30;
  assert.equal(runModel(g).total, 90);
  assert.match(textOf(RoutePanel(g)), /Orient-Express-Zuschlag/);
});

test("run: without an offered route the panel says so and sends nothing", () => {
  const g = load("operating-route");
  g.state.prompt.actions = [];
  assert.equal(runModel(g).action, null);
  assert.match(runSentence(g), /Kein Zug kann fahren/);
});

test("dividend: every offered kind with amount per share, treasury and the price movement", () => {
  const g = load("operating-dividend");
  const o = dividendOptions(g);
  assert.deepEqual(o.map((x) => [x.kind, x.perShare, x.treasury, x.price, x.move]), [
    ["withhold", 0, 60, 60, "down"], ["half", 3, 36, 65, "same"], ["payout", 6, 12, 70, "up"],
  ]);
  assert.deepEqual(o.map((x) => x.label), ["Einbehalten", "Hälfte ausschütten", "Alles ausschütten"]);
});

test("dividend: nothing is chosen until the player picks; the order sends exactly the offered action", () => {
  const g = load("operating-dividend");
  assert.equal(chosenOption(g, null), null);
  assert.equal(dividendOrder(g, null).action, null);
  const o = dividendOrder(g, "payout");
  assert.equal(o.action, g.state.prompt.actions[2]);
  assert.match(o.sentence, /KSS: Alles ausschütten\. Je Anteil £6, Kasse £12, Kurs £65 nach £70/);
  assert.deepEqual(o.changes.map((c) => [c.label, c.before, c.after]), [["Kasse KSS", "£0", "£12"], ["Kurs KSS", "£65", "£70"]]);
  assert.equal(dividendOrder(g, "nonsense").action, null, "a pick that is not offered is nothing");
});

// #294: a fractional rate per share (rulebook §11.4 example 2: £70, half pay, 4 shares = £8.75) threw in
// formatGeld and blanked the whole frame in the owner's game. Shown with decimals, plus what each holder gets.
test("dividend with a fractional rate per share: shown as £8,75 with the rounded-up payouts, nothing throws", () => {
  const g = load("operating-dividend-fraction");
  const o = dividendOptions(g);
  assert.deepEqual(o.map((x) => [x.kind, x.perShare, x.treasury]), [["withhold", 0, 70], ["half", 8.75, 44], ["payout", 17.5, 18]]);
  const half = dividendOrder(g, "half");
  assert.match(half.sentence, /Je Anteil £8,75, Kasse £44/);
  assert.match(half.sentence, /Auszahlung \(je Empfänger aufgerundet\): p0 £18, p1 £9\./);
  assert.match(dividendOrder(g, "payout").sentence, /Je Anteil £17,50.*p0 £35, p1 £18/);
  const text = textOf(DividendPanel(g, "half", noop));
  assert.match(text, /£8,75/);
  assert.match(text, /£17,50/);
  assert.match(textOf(OperatingPanel(g, "half", noop)), /£8,75/);
});

test("dividend without the view's context (older state): kinds still offered, amounts unknown", () => {
  const g = load("dividend");
  const o = dividendOptions(g);
  assert.equal(o.length, 3);
  assert.ok(o.every((x) => x.perShare === null && x.move === null));
  assert.ok(dividendOrder(g, "half").action);
});

test("dividend panel: selection marks the row, rows are buttons; buttons are disabled when not the viewer's turn", () => {
  const g = load("operating-dividend");
  const p = DividendPanel(g, "half", noop);
  const rows = find(p, (n) => n.attrs["data-kind"] !== undefined);
  assert.equal(rows.length, 3);
  assert.deepEqual(rows.map((r) => r.attrs["aria-pressed"]), ["false", "true", "false"]);
  g.state.prompt.viewer_to_act = false;
  assert.ok(find(DividendPanel(g, null, noop), (n) => n.attrs["data-kind"] !== undefined).every((r) => r.attrs.disabled === ""));
  assert.match(textOf(OperatingPanel(g, null, noop)), /entscheidet/);
});

test("claims: the panel takes run_routes and dividend of its steps; the generic bar keeps the rest", () => {
  const g = load("operating-dividend");
  const claims = createClaims();
  assert.equal(genericModel(g, claims).groups.length, 1);
  claims.claim("Dividend", "dividend");
  assert.equal(genericModel(g, claims).count, 0);
});

test("generic bar: a choose action shows the engine's label and the question, not raw keys (#173)", () => {
  const g = load("operating-dividend");
  g.state.prompt.step = "Exchange";
  g.state.prompt.choice_name = "Convert";
  g.state.prompt.actions = [
    { type: "choose", entity: "p0", entity_type: "player", choice: "convert", target: "KSS" },
    { type: "choose", entity: "p0", entity_type: "player", choice: "skip" },
    { type: "choose", entity: "p0", entity_type: "player", choice: "unlabelled" },
  ];
  g.state.prompt.choices = [
    { choice: "convert", target: "KSS", entity: "p0", label: "Convert to Major" },
    { choice: "skip", target: null, entity: "p0", label: "Do not convert" },
  ];
  assert.equal(choiceLabel(g, g.state.prompt.actions[0]!), "Convert to Major · für KSS");
  const m = genericModel(g, createClaims());
  assert.equal(m.groups[0]!.label, "Auswahl treffen: Convert");
  assert.deepEqual(m.groups[0]!.entries.map((e) => e.detail), ["Convert to Major · für KSS", "Do not convert", "choice unlabelled"]);
});

test("private choices: German label and tooltip from text.ts (#290)", () => {
  const g = load("operating-dividend");
  const flip = { type: "choose", entity: "p0", entity_type: "player", choice: "flip_private", target: "PeC" };
  g.state.prompt.actions = [flip];
  g.state.prompt.choices = [{ choice: "flip_private", target: "PeC", entity: "p0", label: "Flip face down" }];
  assert.match(choiceLabel(g, flip)!, /^Schließen \(umdrehen\).*· für PeC$/);
  assert.match(choiceTip(flip)!, /zählt nicht mehr zum Zertifikatslimit/);
});

test("#55: the Route step offers the trains the Pullman may be attached to; a click sends the choose action", () => {
  const g = load("operating-route");
  const corp = operator(g)!.id;
  const choose = { type: "choose", entity: corp, entity_type: "corporation", choice: "pullman_on:2+2-0" };
  g.state.prompt.actions.push(choose);
  g.state.prompt.choices = [{ choice: "pullman_on:2+2-0", target: null, entity: corp, label: "Attach Pullman to the 2+2 train" }];
  assert.deepEqual(pullmanOptions(g).map((o) => o.choice), ["pullman_on:2+2-0"]);
  const sent: unknown[] = [];
  const panel = RoutePanel(g, (a) => sent.push(a));
  assert.match(textOf(panel), /Attach Pullman to the 2\+2 train/);
  find(panel, (n) => n.attrs["data-pullman"] === "pullman_on:2+2-0")[0]!.on.click!(new Event("click"));
  assert.deepEqual(sent, [choose]);
  assert.deepEqual(pullmanOptions(load("operating-route")), [], "nothing without the Pullman choices");
});

test("run: sea crossings and ferries of the stored run get a line with what counts against the city limit (#362)", () => {
  const g = load("operating-dividend");
  g.state.prompt.context!.dividend!.routes = [{
    train: "3-0", hexes: ["I52", "I50"], revenue: 40, distance_str: "2+1~",
    sea: [{ from: "I52", from_exit: 3, to: "I50", to_exit: 0, zones: 2, counted: 1, reductions: [{ kind: "port_token", units: 1 }] }],
    ferries: [{ ferry: "AA20-AB27", distance: 1, counted: 1 }],
  }];
  const lines = runLines(g);
  assert.deepEqual(lines[0]!.sea, ["Seefahrt I52 – I50: 2 Seezonen, 1 zählen, Hafenmarke −1", "Fähre AA20-AB27: Distanz 1, 1 zählt"]);
  assert.match(textOf(DividendPanel(g, "half", noop)), /3-0: Seefahrt I52 – I50/);
});

test("#56: the Route step offers the port authority markers a major may buy; a click sends the choose action", () => {
  const g = load("operating-route");
  const corp = operator(g)!.id;
  const choose = { type: "choose", entity: corp, entity_type: "corporation", choice: "port_authority:north_sea" };
  g.state.prompt.actions.push(choose);
  g.state.prompt.choices = [{ choice: "port_authority:north_sea", target: null, entity: corp, label: "Buy the North Sea port authority marker (£125)" }];
  assert.deepEqual(portAuthorityOptions(g).map((o) => o.choice), ["port_authority:north_sea"]);
  assert.deepEqual(pullmanOptions(g), [], "a marker choice is not a Pullman");
  const sent: unknown[] = [];
  const panel = RoutePanel(g, (a) => sent.push(a));
  assert.match(textOf(panel), /Buy the North Sea port authority marker/);
  find(panel, (n) => n.attrs["data-port-authority"] === "port_authority:north_sea")[0]!.on.click!(new Event("click"));
  assert.deepEqual(sent, [choose]);
  assert.deepEqual(portAuthorityOptions(load("operating-route")), []);
});
