// Operating sheet (#49): the pure model on recorded states. `operating-route` is the recorded Route step of
// corporation B; `operating-dividend` the recorded Dividend step of KSS with a view context built by hand in
// the format of lib/oe/view.rb (dividend_context), to be replaced by a recorded one.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { Game } from "../types.ts";
import { createClaims } from "../ui/frame/claims.ts";
import { choiceLabel, genericModel } from "../ui/frame/generic.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { chosenOption, dividendOptions, dividendOrder, headOf, ladderIndex, operator, runModel, runSentence } from "../ui/panels/operating-model.ts";
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
