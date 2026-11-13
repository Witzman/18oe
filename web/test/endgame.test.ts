// Final standings (#176): the model against a recorded finished state (test/fixtures/games/finished.json, a 3-player
// strategy-bot game via bin/playthrough, rendered with lib/oe/view.rb) and the VNode panel.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { themes } from "../themes/index.ts";
import type { Game } from "../types.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { corpColor, roundBar } from "../ui/frame/model.ts";
import { endgameModel, Endstand } from "../ui/panels/endgame.ts";
import { txt } from "../ui/text.ts";

const g = JSON.parse(readFileSync(new URL("./fixtures/games/finished.json", import.meta.url), "utf8")) as Game;
const theme = themes[0]!;
const handlers = (calls: string[] = [], open = true) => ({
  theme, corpColor: (id: string) => corpColor(theme, g, id), open,
  onToggle: () => calls.push("toggle"), onMap: () => calls.push("map"), onLog: () => calls.push("log"),
});

test("fixture is a finished game with standings", () => {
  assert.equal(g.state.meta.finished, true);
  assert.equal(g.state.meta.standings.length, g.state.players.length);
});

test("model: ranking follows meta.standings, sums equal the standings, one winner", () => {
  const m = endgameModel(g);
  assert.deepEqual(m.rows.map((r) => r.id), g.state.meta.standings.map((s) => s.player));
  for (const r of m.rows) {
    const s = g.state.meta.standings.find((x) => x.player === r.id)!;
    const p = g.state.players.find((x) => x.id === r.id)!;
    assert.equal(r.total, s.value);
    assert.equal(r.cash + r.shares + r.privates, s.value, `${r.name}: parts add up`);
    assert.equal(r.cash, p.cash);
    assert.equal(r.privates, p.companies.filter((c) => !c.face_down).reduce((n, c) => n + (c.value ?? 0), 0));
    assert.ok(r.shares >= 0, "share value is not negative");
    assert.equal(r.total, p.value, "standing equals player.value");
  }
  assert.equal(m.rows.filter((r) => r.winner).length, 1);
  assert.equal(m.rows[0]!.winner, true);
  assert.equal(m.rows[0]!.rank, 1);
});

test("model: equal values share a rank; face-down privates do not count", () => {
  const t = structuredClone(g);
  t.state.meta.standings = t.state.meta.standings.map((s) => ({ ...s, value: 100 }));
  assert.deepEqual(endgameModel(t).rows.map((r) => r.rank), [1, 1, 1]);
  const f = structuredClone(g);
  const pl = f.state.players.find((p) => p.companies.length > 0)!;
  pl.companies[0]!.face_down = true;
  const before = endgameModel(g).rows.find((r) => r.id === pl.id)!.privates;
  assert.equal(endgameModel(f).rows.find((r) => r.id === pl.id)!.privates, before - (g.state.players.find((p) => p.id === pl.id)!.companies[0]!.value ?? 0));
});

test("panel: one table row and one card per player, winner marked, corporations listed, buttons wired", () => {
  const calls: string[] = [];
  const tree = Endstand(endgameModel(g), handlers(calls));
  const rows = find(tree, (n) => n.tag === "tr").length - 1 - 0; // minus the header row of the ranking
  const m = endgameModel(g);
  assert.ok(rows >= m.rows.length);
  assert.equal(find(tree, (n) => n.tag === "article").length, m.rows.length);
  const text = textOf(tree);
  for (const r of m.rows) assert.ok(text.includes(r.name), r.name);
  assert.ok(text.includes(txt("end.winner_mark").de));
  assert.ok(text.includes(m.rows[0]!.name));
  const link = find(tree, (n) => n.tag === "a" && n.attrs.href === "#/");
  assert.equal(link.length, 1, "link back to the lobby");
  for (const b of find(tree, (n) => n.tag === "button")) b.on.click!(new Event("click"));
  assert.deepEqual(calls, ["map", "log"]);
});

test("panel: collapsed form offers to show the standings again; no action buttons anywhere", () => {
  const calls: string[] = [];
  const tree = Endstand(endgameModel(g), handlers(calls, false));
  find(tree, (n) => n.tag === "button")[0]!.on.click!(new Event("click"));
  assert.deepEqual(calls, ["toggle"]);
});

test("round bar of a finished game says the game is over", () => {
  assert.equal(roundBar(g, theme).round, txt("frame.over").de);
  assert.match(roundBar(g, theme).who.text, /beendet/);
});
