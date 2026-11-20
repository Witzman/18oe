// Action kinds of the action box (#497 S1): the engine's offered actions (prompt.actions) sorted into kinds,
// pure and under node. Recorded states from test/fixtures/games; cases no fixture holds are built from the
// Action shape of types.ts / lib/oe/legal_actions.rb (stock_choices) and marked "constructed".
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import type { Game } from "../types.ts";
import { actionsOfKind, kindGroups, kindOfAction, KINDS, kindsOf, usesKinds, type Kind } from "../ui/frame/kinds.ts";
import { TEXT, txt } from "../ui/text.ts";

const dir = new URL("./fixtures/games/", import.meta.url).pathname;
const games = Object.fromEntries(readdirSync(dir).filter((f) => f.endsWith(".json")).map((f) => [f.slice(0, -5), JSON.parse(readFileSync(join(dir, f), "utf8")) as Game]));
type Action = Record<string, unknown>;
const withActions = (g: Game, actions: Action[], step = "BuySellParShares"): Game =>
  ({ ...g, state: { ...g.state, prompt: { ...g.state.prompt, step, actions } } }) as Game;
const stockGames = ["stock", "stock-pool", "stock-par"] as const;
const concessionGames = Object.keys(games).filter((n) => n.startsWith("concession"));

test("kinds apply only to the stock round step and the concession step, never to the operating round", () => {
  for (const n of [...stockGames, ...concessionGames]) assert.ok(usesKinds(games[n]!), n);
  for (const n of ["auction", "track", "operating-route", "buy-train", "dividend"]) {
    assert.equal(usesKinds(games[n]!), false, n);
    assert.deepEqual(kindsOf(games[n]!), [], n);
    assert.deepEqual(kindGroups(games[n]!), [], n);
  }
});

test("every offered action of the stock and concession fixtures lands in exactly one kind, none is lost", () => {
  let total = 0;
  for (const n of [...stockGames, ...concessionGames]) {
    const g = games[n]!;
    const groups = kindGroups(g);
    const flat = groups.flatMap((x) => x.actions);
    assert.equal(flat.length, g.state.prompt.actions.length, n);
    for (const a of g.state.prompt.actions) {
      assert.equal(flat.filter((x) => x === a).length, 1, `${n}: ${JSON.stringify(a)}`);
      assert.ok(actionsOfKind(g, kindOfAction(g, a)).includes(a), n);
      total++;
    }
    assert.deepEqual(groups.map((x) => x.kind), kindsOf(g), n);
    assert.equal(new Set(groups.map((x) => x.kind)).size, groups.length, `${n}: a kind twice`);
  }
  assert.ok(total > 500, `only ${total} actions checked`);
});

test("a kind is listed only when an offered action fits, in the fixed order", () => {
  for (const n of [...stockGames, ...concessionGames]) {
    const kinds = kindsOf(games[n]!);
    assert.ok(kinds.length > 0, n);
    assert.deepEqual(kinds, KINDS.filter((k) => kinds.includes(k)), `${n}: not in the fixed order`);
  }
  assert.deepEqual(kindsOf(withActions(games["stock"]!, [])), []);
});

test("concession round: only founding kinds, never pass or remove (§8.1)", () => {
  for (const n of concessionGames) {
    for (const k of kindsOf(games[n]!)) assert.ok(["float_minor", "float_regional", "par_regional"].includes(k), `${n}: ${k}`);
  }
  assert.deepEqual(kindsOf(games["concession-minor"]!), ["float_regional", "float_minor"]);
  assert.deepEqual(kindsOf(games["concession"]!), ["float_minor"]);
  assert.deepEqual(kindsOf(games["concession-paronly"]!), ["par_regional"]);
  assert.deepEqual(kindsOf(games["concession-regional"]!), ["float_regional"]);
});

test("stock round fixtures: par floats at once, choose splits by choice and target", () => {
  const stock = games["stock"]!;
  const kinds = kindsOf(stock);
  assert.ok(kinds.includes("private_close") && kinds.includes("private_remove") && kinds.includes("remove_regional"), kinds.join());
  assert.ok(!kinds.includes("pass"), "stock.json offers no pass");
  assert.ok(!kinds.includes("par_regional"), "a regional par in the stock round is Regional floaten");
  for (const a of actionsOfKind(stock, "private_close")) assert.deepEqual([a.choice, a.target_type], ["flip_private", "company"]);
  for (const a of actionsOfKind(stock, "private_remove")) assert.deepEqual([a.choice, a.target_type], ["remove_private", "company"]);
  for (const a of actionsOfKind(stock, "remove_regional")) assert.deepEqual([a.choice, a.target_type], ["remove", "corporation"]);
  const pool = games["stock-pool"]!;
  assert.deepEqual(kindsOf(pool), ["buy", "sell", "offer", "pass"], "L is a minor merge offer (choose without target)");
  const par = games["stock-par"]!;
  assert.deepEqual(kindsOf(par), ["float_regional", "buy", "remove_regional", "pass"]);
  assert.deepEqual(kindsOf(stock), ["float_minor", "remove_regional", "private_close", "private_remove"]);
});

test("par of a minor is Minor floaten, of a regional Regional floaten (stock round)", () => {
  const g = games["stock-par"]!;
  const minorId = g.state.corporations.find((c) => c.type === "minor")?.id;
  const regionalId = g.state.corporations.find((c) => c.type === "regional")?.id;
  assert.ok(minorId && regionalId);
  const base = { type: "par", entity: "p3", entity_type: "player", share_price: "90,1,0" };
  const m = { ...base, corporation: minorId }, r = { ...base, corporation: regionalId };
  const gg = withActions(g, [m, r]);
  assert.equal(kindOfAction(gg, m), "float_minor");
  assert.equal(kindOfAction(gg, r), "float_regional");
  assert.deepEqual(kindsOf(gg), ["float_regional", "float_minor"]);
});

test("constructed: choices no fixture holds (reserve, offer_or_merge, bbbt, convert, trade) and unknown types", () => {
  const g = games["stock-pool"]!;
  const ch = (choice: string, target?: string, target_type?: string): Action => ({ type: "choose", entity: "p0", entity_type: "player", choice, ...(target ? { target, target_type } : {}) });
  const cases: [Action, Kind][] = [
    [ch("reserve", "LNWR", "corporation"), "reserve"],
    [ch("offer_or_merge", "LNWR", "corporation"), "offer"],
    [ch("L"), "offer"],
    [ch("bbbt_custody:LNWR", "BBBT", "company"), "private_act"],
    [ch("bbbt_protect:LNWR", "BBBT", "company"), "private_act"],
    [ch("bbbt_repar:90", "BBBT", "company"), "private_act"],
    [ch("something_new", "WS", "company"), "private_act"],
    [ch("something_new", "LNWR", "corporation"), "other"],
    [{ type: "convert", entity: "p0", entity_type: "player", corporation: "LNWR" }, "convert"],
    [{ type: "buy_company", entity: "p0", entity_type: "player", company: "WS", price: 10 }, "trade"],
    [{ type: "buy_corporation", entity: "p0", entity_type: "player", corporation: "L", price: 10 }, "trade"],
    [{ type: "skip", entity: "p0", entity_type: "player" }, "other"],
    [{ type: "never_seen", entity: "p0" }, "other"],
  ];
  const all = withActions(g, cases.map(([a]) => a));
  for (const [a, k] of cases) assert.equal(kindOfAction(all, a), k, JSON.stringify(a));
  assert.equal(kindGroups(all).flatMap((x) => x.actions).length, cases.length);
  assert.deepEqual(kindsOf(all), KINDS.filter((k) => cases.some(([, c]) => c === k)));
});

test("every kind has German and English texts and a tooltip; back and pick exist", () => {
  for (const k of KINDS) {
    for (const key of [`kind.${k}`, `kind.${k}_tip`]) {
      assert.ok(TEXT[key], key);
      assert.notEqual(txt(key).de, txt(key).en, key);
    }
  }
  for (const key of ["kind.back", "kind.pick", "kind.step_head"]) assert.ok(TEXT[key], key);
});
