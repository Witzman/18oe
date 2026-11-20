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
  assert.match(b.sentence, /your turn/);
  assert.ok(b.acting!.color.length > 0);
});

test("a bot's or another player's company acting says who operates", () => {
  const g = load("operating-route");
  g.state.meta.current = { kind: "corporation", id: "D", owner: "p3" };
  g.state.meta.operating_order = g.state.meta.operating_order.map((o) => ({ ...o, done: ["A", "B"].includes(o.id) }));
  const b = orBand(g, theme)!;
  assert.equal(b.acting!.id, "D");
  assert.match(b.sentence, /operates: p3 \(Bot\)/);
  const view = OrBandView(b, theme);
  assert.equal(find(view, (n) => n.attrs["data-state"] === "current").length, 1);
  assert.match(textOf(view), /has operated/);
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
  assert.deepEqual(find(OrderBandView(b, theme), (n) => n.attrs.class === "order-band-title").map(textOf), ["Turn order"]);
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
  assert.match(roundShort(g), /^OR \d+\.\d+$/);
  const strip = OrderBandView(orBand(g, theme)!, theme);
  const items = find(strip, (n) => n.attrs.class === "order-strip-item");
  assert.deepEqual(items.map((n) => n.attrs["data-state"]), ["done", "current", "next", "next", "next", "next"]);
  assert.equal(items.filter((n) => n.attrs["aria-current"] === "step").length, 1);
  // Board look (#478): numbered cells, finished and running ones marked by a sign, not by colour only.
  assert.deepEqual(find(strip, (n) => n.attrs.class === "order-strip-no").map(textOf), ["1", "2", "3", "4", "5", "6"]);
  assert.deepEqual(find(strip, (n) => n.attrs.class === "order-strip-mark").map(textOf), ["✓", "▶", "", "", "", ""]);
  // #526: no fold button; the owner is a ring in the player colour around the seal.
  assert.equal(find(strip, (n) => n.tag === "button").length, 0);
  const rings = find(strip, (n) => n.attrs.class === "order-strip-ring");
  assert.equal(rings.length, 6);
  assert.ok(rings.every((n) => /^box-shadow:0 0 0 var\(--shape-order-ring\) var\(--player-p[1-7]\)$/.test(n.attrs.style ?? "")));
  g.state.meta.round = { type: "stock", number: 3, turn: 1, description: null };
  assert.equal(roundShort(g), "SR 3");
});
