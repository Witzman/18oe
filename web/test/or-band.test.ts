// Acting company and operating order (#291): pure model under node on recorded operating states.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { themes } from "../themes/index.ts";
import type { Game } from "../types.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { OrBandView, orBand } from "../ui/frame/or-band.ts";

const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/games/${n}.json`, import.meta.url), "utf8")) as Game;
const theme = themes[0]!;

test("order: done ones checked, current one marked, rest follow; owner, own and bot marks", () => {
  const b = orBand(load("operating-route"), theme)!;
  assert.deepEqual(b.entries.map((e) => `${e.id}:${e.state}`), ["A:done", "B:current", "D:next", "F:next", "H:next", "M:next"]);
  assert.equal(b.entries.find((e) => e.id === "A")!.bot, true);
  assert.equal(b.entries.find((e) => e.id === "B")!.mine, true);
  assert.equal(b.entries.find((e) => e.id === "F")!.mine, true);
  assert.equal(b.entries.find((e) => e.id === "H")!.mine, false);
  assert.equal(b.acting!.id, "B");
  assert.match(b.sentence, /du bist am Zug/);
  assert.ok(b.acting!.color.length > 0);
});

test("a bot's or another player's company acting says who operates", () => {
  const g = load("operating-route");
  g.state.meta.current = { kind: "corporation", id: "D", owner: "p3" };
  g.state.meta.operating_order = g.state.meta.operating_order.map((o) => ({ ...o, done: ["A", "B"].includes(o.id) }));
  const b = orBand(g, theme)!;
  assert.equal(b.acting!.id, "D");
  assert.match(b.sentence, /operiert: p3 \(Bot\)/);
  const view = OrBandView(b, theme);
  assert.equal(find(view, (n) => n.attrs["data-state"] === "current").length, 1);
  assert.match(textOf(view), /hat operiert/);
});

test("no band outside an operating round or without an order", () => {
  assert.equal(orBand(load("stock"), theme), null);
  const g = load("operating-route");
  g.state.meta.operating_order = [];
  assert.equal(orBand(g, theme), null);
});
