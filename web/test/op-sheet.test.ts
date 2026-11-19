// Operating round in the action panel (#302): head of the acting company with the step strip, the run's hexes
// for the map, the one-line dividend options and the payout list. Pure models on recorded states.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { Game } from "../types.ts";
import { themes, DEFAULT_THEME_ID } from "../themes/index.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { opSheet, OpSheetView } from "../ui/panels/op-sheet.ts";
import { dividendOptions, optionLine, payoutRows, runBands, runHexes, runLines } from "../ui/panels/operating-model.ts";
import { DividendPanel } from "../ui/panels/operating.ts";

const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/games/${n}.json`, import.meta.url), "utf8")) as Game;
const theme = themes.find((t) => t.id === DEFAULT_THEME_ID) ?? themes[0]!;
const noop = { onPick: () => {} };

test("head: acting company, du, its numbers in one line and the strip with the current step", () => {
  const g = load("operating-route");
  const s = opSheet(g, theme)!;
  assert.equal(s.id, "B");
  assert.equal(s.who, "du");
  assert.deepEqual(s.facts.map((f) => f.key), ["op.cash", "op.price", "op.trains", "op.tokens"].filter((k) => k !== "op.price" || g.state.corporations.find((c) => c.id === "B")!.share_price !== null));
  assert.equal(s.facts.find((f) => f.key === "op.tokens")!.value, "1/2 frei");
  assert.deepEqual(s.steps.map((x) => x.state), ["done", "done", "current", "next", "next"]);
  const text = textOf(OpSheetView(s));
  assert.match(text, /B · du/);
  assert.match(text, /3 Fahrt/);
  assert.equal(find(OpSheetView(s), (n) => n.attrs["aria-current"] === "step").length, 1);
});

test("head: nothing outside the operating round; a bot's company is named with its owner", () => {
  assert.equal(opSheet(load("stock"), theme), null);
  const g = load("operating-route");
  const b = g.state.corporations.find((c) => c.id === "B")!;
  const other = g.state.players.find((p) => p.id !== g.viewer)!;
  b.president = other.id;
  const s = opSheet(g, theme)!;
  assert.equal(s.mine, false);
  assert.match(s.who, new RegExp(other.name));
});

test("run: route step hexes from the offered run, dividend step from the view's routes (once each)", () => {
  const r = load("operating-route");
  assert.deepEqual(runHexes(r), ["H21", "G24", "G26"]);
  assert.equal(runLines(r)[0]!.revenue, 60);
  const d = load("operating-dividend");
  assert.deepEqual(runHexes(d), [], "older states carry no routes");
  d.state.prompt.context!.dividend!.routes = [{ train: "2+2", hexes: ["H21", "G24"], revenue: 40 }, { train: "3", hexes: ["G24", "G26"], revenue: 20 }];
  assert.deepEqual(runHexes(d), ["H21", "G24", "G26"]);
  assert.match(textOf(DividendPanel(d, null, noop)), /2\+2: H21 – G24 £40/);
});

test("dividend: one line per option with share, treasury and price; payout list for the pick, else full payout", () => {
  const g = load("operating-dividend");
  const now = g.state.corporations.find((c) => c.id === "KSS")!.share_price;
  const lines = dividendOptions(g).map((o) => optionLine(o, now));
  assert.deepEqual(lines, ["£60 in die Kasse · Kurs £65 → £60", "£3 je Anteil · £36 in die Kasse · Kurs bleibt", "£6 je Anteil · £12 in die Kasse · Kurs £65 → £70"]);
  const f = load("operating-dividend-fraction");
  assert.equal(payoutRows(f, null)!.kind, "payout");
  assert.equal(payoutRows(f, "half")!.kind, "half");
  assert.deepEqual(payoutRows(f, "half")!.rows.map((r) => [r.name, r.amount]), [["p0", 18], ["p1", 9]]);
  assert.equal(payoutRows(f, "withhold"), null, "withhold pays nobody");
});

test("head: a state without the operating order still names the current company (older states)", () => {
  const g = load("buy-train-reserved");
  const s = opSheet(g, theme)!;
  assert.equal(s.id, "B");
  assert.equal(s.steps.find((x) => x.state === "current")!.step, "BuyTrain");
});

test("#55: the head shows the company's Pullman once Pullman cars are on sale (§11.6.2)", () => {
  const g = load("operating-route");
  const facts = (gg: Game) => opSheet(gg, theme)!.facts;
  assert.ok(!facts(g).some((f) => f.key === "op.pullman"), "not before the first 4 train, nor on a state without the field");
  g.state.depot.pullmans = { available: true, supply: 9, market: 0 };
  const b = g.state.corporations.find((c) => c.id === "B")!;
  b.pullman = false;
  assert.equal(facts(g).find((f) => f.key === "op.pullman")!.value, "keine");
  b.pullman = true;
  assert.equal(facts(g).find((f) => f.key === "op.pullman")!.value, "ja");
});

test("#56: the head names the water area of the company's port authority marker (§11.3.5)", () => {
  const g = load("operating-route");
  const facts = (gg: Game) => opSheet(gg, theme)!.facts;
  assert.ok(!facts(g).some((f) => f.key === "op.port_authority"), "no marker, no fact");
  g.state.corporations.find((c) => c.id === "B")!.port_authority = "north_sea";
  assert.equal(facts(g).find((f) => f.key === "op.port_authority")!.value, "Nordsee");
});

test("run bands (#155): the offered run of the active company, chains and stops as the prompt carries them", () => {
  const r = load("operating-route");
  const run = runBands(r)!;
  assert.equal(run.corporation, "B");
  assert.equal(run.routes.length, 1);
  assert.deepEqual(run.routes[0]!.connections, [["H21", "G22", "G24"], ["G24", "G26"]]);
  assert.deepEqual(run.routes[0]!.nodes, ["H21-0", "G24-0", "G26-0"]);
  assert.equal(run.routes[0]!.revenue, 60);
  assert.match(run.routes[0]!.label!, /^2\+2 £60$/, "shield: train name and the sum");
  assert.equal(runBands(load("operating-dividend")), null, "only the Route step shows the proposal");
  assert.equal(runBands(load("stock")), null);
  const none = load("operating-route");
  delete none.state.prompt.actions.find((a) => a.type === "run_routes")!.routes;
  assert.equal(runBands(none), null);
});
