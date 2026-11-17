// Acting company and operating order (#291): pure model under node on recorded operating states.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { themes } from "../themes/index.ts";
import type { Game } from "../types.ts";
import { roundShort } from "../ui/frame/model.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { OrBandView, OrderBandView, orBand } from "../ui/frame/or-band.ts";

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

test("stock round (#416): preview of the next operating order, nobody acting, nothing done", () => {
  const g = load("stock");
  assert.equal(orBand(g, theme), null); // the recorded stock view predates operating_order outside an OR: no order, no band
  g.state.meta.operating_order = load("operating-route").state.meta.operating_order;
  g.state.corporations = load("operating-route").state.corporations;
  const b = orBand(g, theme);
  assert.ok(b && b.preview === true && b.acting === null);
  assert.deepEqual(b.entries.map((e) => e.id), g.state.meta.operating_order.map((o) => o.id));
  assert.ok(b.entries.every((e) => e.state === "next"));
});

test("no band without an order or when the game is over", () => {
  const f = load("operating-route");
  f.state.meta.finished = true;
  assert.equal(orBand(f, theme), null);
  const g = load("operating-route");
  g.state.meta.operating_order = [];
  assert.equal(orBand(g, theme), null);
});

test("head bar (#300): short round label and the compact order strip", () => {
  const g = load("operating-route");
  assert.match(roundShort(g), /^BR \d+\.\d+$/);
  const strip = OrderBandView(orBand(g, theme)!, theme, { collapsed: false, onToggle: () => {} });
  const items = find(strip, (n) => n.attrs.class === "order-strip-item");
  assert.deepEqual(items.map((n) => n.attrs["data-state"]), ["done", "current", "next", "next", "next", "next"]);
  assert.equal(items.filter((n) => n.attrs["aria-current"] === "step").length, 1);
  const folded = OrderBandView(orBand(g, theme)!, theme, { collapsed: true, onToggle: () => {} });
  assert.equal(find(folded, (n) => n.attrs.class === "order-strip-item").length, 0);
  const btn = find(folded, (n) => n.tag === "button")[0]!;
  assert.equal(btn.attrs["aria-expanded"], "false");
  g.state.meta.round = { type: "stock", number: 3, turn: 1, description: null };
  assert.equal(roundShort(g), "AR 3");
});
