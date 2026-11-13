// Token panel (#174): the pure model on a recorded real state (token-place = regional G in its token step,
// two reachable cities AC16 and Y14, one token left, recorded with Oe::View from a strategy game).
// Acceptance (#278): every offered place_token is reachable through the panel, nothing else can be sent.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { Game } from "../types.ts";
import { createClaims } from "../ui/frame/claims.ts";
import { genericModel } from "../ui/frame/generic.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { TokenPanel, effectiveCity, orderFor, previewFor, sentenceFor, tapMap, targetsFor, tokenTargets } from "../ui/panels/token.ts";

const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/games/${n}.json`, import.meta.url), "utf8")) as Game;
const noop = { onCity: () => {}, onMap: () => {} };
const places = (g: Game) => g.state.prompt.actions.filter((a) => a.type === "place_token");

test("targets: from prompt.actions, hex, city and price from context.token; map targets at the city", () => {
  const g = load("token-place");
  assert.deepEqual(tokenTargets(g).map((t) => [t.id, t.hex, t.city, t.price]), [["57-7-0", "AC16", 0, 20], ["OE4-2-1", "Y14", 1, 20]]);
  assert.deepEqual(targetsFor(g), { cities: [{ hex: "AC16", city: 0 }, { hex: "Y14", city: 1 }], kind: "token" });
});

test("acceptance: every offered placement is reachable, by row and by map tap; nothing else is sendable", () => {
  const g = load("token-place");
  const reached = tokenTargets(g).map((t) => sentenceFor(g, t.id).action);
  assert.deepEqual(reached, places(g));
  assert.equal(sentenceFor(g, "X-0").action, null, "an unknown city sends nothing");
  assert.equal(sentenceFor(g, null).action, null, "two choices: nothing picked yet");
  assert.equal(tapMap(g, "Y14", 1), "OE4-2-1");
  assert.equal(tapMap(g, "Y14"), "OE4-2-1", "a hex with one target picks it");
  assert.equal(tapMap(g, "Y14", 0), "OE4-2-1", "another slot of that hex: the hex's only target");
  assert.equal(tapMap(g, "A2"), null);
});

test("order: preview on the slot, sentence with price, cash and tokens before/after, pass as side button", () => {
  const g = load("token-place");
  const sent: unknown[] = [];
  const none = orderFor(g, null, (a) => sent.push(a))!;
  assert.equal(none.state, "invalid");
  assert.equal(previewFor(g, null), null);
  assert.deepEqual(previewFor(g, "57-7-0"), { hex: "AC16", city: 0, corp: "G" });
  const o = orderFor(g, "57-7-0", (a) => sent.push(a))!;
  assert.equal(o.state, "preview");
  assert.match(o.sentence, /G setzt eine Station in AC16 \(Stadt 1\) für £20/);
  assert.deepEqual(o.changes!.map((c) => [c.label, c.before, c.after]), [["Kasse G", "£20", "£0"], ["Stationen übrig", "1", "0"]]);
  assert.deepEqual(o.side!.map((s) => s.label), ["Keine Station"]);
  assert.equal(sent.length, 0);
  o.onConfirm();
  assert.deepEqual(sent, [places(g)[0]]);
});

test("a single target is previewed right away", () => {
  const g = load("token-place");
  g.state.prompt.actions = g.state.prompt.actions.filter((a) => a.city !== "OE4-2-1");
  assert.equal(effectiveCity(g, null), "57-7-0");
  assert.equal(orderFor(g, null, () => {})!.state, "preview");
});

test("claims and panel: generic bar empty; rows per city; others only see who places", () => {
  const g = load("token-place");
  const claims = createClaims();
  claims.claim("Token", "place_token");
  claims.claim("Token", "pass");
  assert.equal(genericModel(g, claims).count, 0);
  const p = TokenPanel(g, "OE4-2-1", noop);
  assert.deepEqual(find(p, (n) => n.attrs.class === "token-city").map((n) => [n.attrs["data-city"], n.attrs["aria-pressed"]]), [["57-7-0", "false"], ["OE4-2-1", "true"]]);
  assert.match(textOf(p), /Stationen übrig: 1, nächste für £20/);
  const other = structuredClone(g);
  other.state.prompt.viewer_to_act = false;
  other.state.prompt.actions = [];
  assert.match(textOf(TokenPanel(other, null, noop)), /G setzt eine Station/);
  assert.equal(orderFor(other, null, () => {}), null);
});
