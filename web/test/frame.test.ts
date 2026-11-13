// Game frame (#45): the pure parts under node (what the bars show, the generic action list, claims,
// view registry). Every action offered in the recorded states (test/fixtures/games, from real engine
// states via lib/oe/view.rb) must be an operable entry that selects exactly that action. The DOM and
// sending are in frame-browser.test.ts.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { themes } from "../themes/index.ts";
import type { Game } from "../types.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { createClaims } from "../ui/frame/claims.ts";
import { actionKey, GenericBar, genericModel, rangeAction, rangeValue, type GenericHandlers } from "../ui/frame/generic.ts";
import { corpColor, outlinerCorps, playerRows, roundBar, whoActs } from "../ui/frame/model.ts";
import { createViews } from "../ui/frame/views.ts";
import { fillText, txt } from "../ui/text.ts";

const dir = new URL("./fixtures/games/", import.meta.url).pathname;
const games = Object.fromEntries(readdirSync(dir).filter((f) => f.endsWith(".json")).map((f) => [f.slice(0, -5), JSON.parse(readFileSync(join(dir, f), "utf8")) as Game]));
const theme = themes[0]!;
const handlers = (picked: unknown[] = []): GenericHandlers => ({ selectedKey: null, onSelect: (e) => { picked.push(e.action); }, onRange: () => {}, rangeError: null });

test("every offered action of every recorded state is a button that selects exactly that action", () => {
  let total = 0;
  for (const [name, g] of Object.entries(games)) {
    const picked: unknown[] = [];
    const bar = GenericBar(genericModel(g, createClaims()), handlers(picked));
    for (const a of g.state.prompt.actions) {
      const btn = find(bar, (n) => n.tag === "button" && n.attrs["data-key"] === actionKey(a));
      assert.equal(btn.length, 1, `${name}: ${JSON.stringify(a)} has no button`);
      btn[0]!.on.click!(new Event("click"));
      assert.deepEqual(picked.at(-1), a, `${name}: selected a different action`);
      total++;
    }
  }
  assert.ok(total > 100, `only ${total} actions checked`);
});

test("every action type of the fixtures has a German label, and the group count matches", () => {
  for (const [name, g] of Object.entries(games)) {
    const m = genericModel(g, createClaims());
    assert.equal(m.count, g.state.prompt.actions.length + g.state.prompt.ranges.length, name);
    for (const gr of m.groups) assert.notEqual(txt(`action.${gr.type}`).de, `action.${gr.type}`, `${name} ${gr.type}`);
  }
});

test("claims: a claimed (step, type) leaves the generic bar, the rest stays; releasing brings it back", () => {
  const g = games["track"]!;
  const claims = createClaims();
  const all = genericModel(g, claims);
  const types = all.groups.map((x) => x.type);
  assert.ok(types.includes("lay_tile") && types.includes("pass"));
  const release = claims.claim("Track", "lay_tile");
  assert.deepEqual(genericModel(g, claims).groups.map((x) => x.type), types.filter((t) => t !== "lay_tile"));
  claims.claim("OtherStep", "pass");
  assert.ok(genericModel(g, claims).groups.some((x) => x.type === "pass"), "claim for another step must not apply");
  release(); release();
  assert.equal(genericModel(g, claims).groups.length, types.length);
  claims.claim("*", "*");
  assert.equal(genericModel(g, claims).count, 0);
});

test("a range is a form; its value must lie on min, min+step .. max and becomes a normal bid action", () => {
  const g = games["auction"]!;
  const m = genericModel(g, createClaims());
  assert.ok(m.ranges.length > 0);
  const r = m.ranges.find((x) => x.range.step === 5)!.range;
  assert.equal(rangeValue(r, String(r.min)), r.min);
  assert.equal(rangeValue(r, String(r.min + r.step)), r.min + r.step);
  assert.equal(rangeValue(r, String(r.min + 1)), null);
  assert.equal(rangeValue(r, String(r.max + r.step)), null);
  assert.equal(rangeValue(r, ""), null);
  assert.equal(rangeValue(r, "x"), null);
  assert.deepEqual(rangeAction(g, r, r.min), { type: "bid", entity: r.entity, entity_type: "player", company: r.company, price: r.min });
  const bar = GenericBar(m, handlers());
  assert.equal(find(bar, (n) => n.tag === "form").length, m.ranges.length);
});

test("unsupported types are named in the bar, not silently dropped", () => {
  const g = structuredClone(games["track"]!);
  g.state.prompt.unsupported = ["Track: borrow_train"];
  const m = genericModel(g, createClaims());
  assert.deepEqual(m.unsupported, ["Track: borrow_train"]);
  assert.match(textOf(GenericBar(m, handlers())), /borrow_train/);
});

test("round bar: phases, round label, who acts (mine, other player, corporation), bank", () => {
  const g = games["track"]!;
  const m = roundBar(g, theme);
  assert.equal(m.rrPhase, g.state.meta.rr_phase);
  assert.equal(m.round, fillText("frame.round_nt", { name: txt("round.operating").de, n: g.state.meta.round.number!, t: g.state.meta.round.turn }));
  assert.equal(m.bank, g.state.bank.cash);
  assert.equal(m.who.mine, true);
  assert.ok(m.who.text.startsWith(txt("frame.who_mine").de.split("{")[0]!));
  assert.ok(m.who.corp, "a corporation acts in the operating round");
  const other = structuredClone(g);
  other.state.prompt.viewer_to_act = false;
  const w = whoActs(other, theme);
  assert.equal(w.mine, false);
  assert.ok(w.text.length > 0 && !w.text.startsWith(txt("frame.who_mine").de.split("{")[0]!));
  const done = structuredClone(g);
  done.state.meta.finished = true;
  done.state.meta.winner = done.state.players[0]!.id;
  assert.match(whoActs(done, theme).text, new RegExp(done.state.players[0]!.name));
});

test("player bar: one entry per player in seat order, one priority star, bots marked, own entry flagged", () => {
  const g = games["stock"]!;
  const rows = playerRows(g);
  assert.deepEqual(rows.map((r) => r.id), g.state.players.map((p) => p.id));
  assert.deepEqual(rows.map((r) => r.seat), rows.map((_, i) => i + 1));
  assert.equal(rows.filter((r) => r.priority).length, 1);
  assert.equal(rows.filter((r) => r.bot).length, g.seats.filter((s) => s.kind === "bot").length);
  assert.equal(rows.filter((r) => r.me).length, 1);
  for (const r of rows) assert.ok(r.certLimit > 0 && r.cash === g.state.players.find((p) => p.id === r.id)!.cash);
});

test("outliner lists founded corporations and counts the rest; company colours cycle through the theme's colours", () => {
  const g = games["track"]!;
  const { shown, hidden } = outlinerCorps(g);
  assert.equal(shown.length + hidden, g.state.corporations.filter((c) => !c.closed).length);
  assert.ok(shown.every((c) => c.ipoed || c.floated));
  const colors = Object.values(theme.company);
  assert.equal(corpColor(theme, g, g.state.corporations[0]!.id), colors[0]);
  assert.equal(corpColor(theme, g, g.state.corporations[colors.length]!.id), colors[0]);
});

test("view registry: first registered view is active, activate switches, unregister falls back", () => {
  const views = createViews();
  let changes = 0;
  views.onChange(() => { changes++; });
  const off1 = views.register({ id: "a", labelKey: "frame.view_map", render: () => {} });
  views.register({ id: "b", labelKey: "frame.view_map", render: () => {} });
  assert.equal(views.activeId, "a");
  views.activate("b");
  assert.equal(views.active?.id, "b");
  views.activate("zzz");
  assert.equal(views.activeId, "b");
  off1();
  assert.deepEqual(views.list.map((d) => d.id), ["b"]);
  assert.ok(changes >= 3);
});

test("frame.css uses only theme variables and no fixed colours (rule 10)", async () => {
  const { themeVars } = await import("../themes/css.ts");
  const css = readFileSync(new URL("../ui/frame/frame.css", import.meta.url), "utf8");
  const defined = new Set(themeVars(theme).map(([name]) => name));
  const used = [...css.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]!);
  assert.ok(used.length > 20);
  assert.deepEqual([...new Set(used)].filter((v) => !defined.has(v)), []);
  assert.deepEqual(css.match(/#[0-9a-f]{3,8}\b|rgba?\(/gi) ?? [], []);
});
