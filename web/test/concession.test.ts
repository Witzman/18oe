// Concession round panel (#172): the pure model on recorded real engine states (test/fixtures/games:
// concession = start of the round with four minors, concession-minor / -regional / -paronly = later offers,
// home-token = a founded minor choosing its city; map-homes.json = excerpt of GET /map for its hexes).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { themes } from "../themes/index.ts";
import type { MapGeometry } from "../render/mapdata.ts";
import type { Game } from "../types.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { ConcessionPanel, effectiveSelection, emptySelection, homeTargets, hexOfCity, ladder, offers, orderFor, parPrice, sentenceFor } from "../ui/panels/concession.ts";
import { createClaims } from "../ui/frame/claims.ts";
import { genericModel } from "../ui/frame/generic.ts";

const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/games/${n}.json`, import.meta.url), "utf8")) as Game;
const map = JSON.parse(readFileSync(new URL("./fixtures/map-homes.json", import.meta.url), "utf8")) as unknown as MapGeometry;
const noop = { onCorp: () => {}, onPrice: () => {}, onCity: () => {} };

test("ladder: CON1..CON10 with owner and status; the current one is active, mine are marked", () => {
  const rows = ladder(load("concession"));
  assert.equal(rows.length, 10);
  assert.deepEqual(rows.map((r) => r.n), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  assert.equal(rows[0]!.state, "active");
  assert.ok(rows.slice(1).every((r) => r.state === "future"));
  assert.deepEqual(rows.filter((r) => r.mine).map((r) => r.id), ["CON1", "CON6", "CON8"]);
  assert.equal(rows[1]!.owner, "p2");
  const later = ladder(load("concession-regional"));
  assert.ok(later.some((r) => r.state === "done") && later.filter((r) => r.state === "active").length === 1);
});

test("offers at the start: four minors, every par value offered, nothing to pay as a regional", () => {
  const o = offers(load("concession"));
  assert.deepEqual(o.map((x) => x.corp), ["B", "C", "F", "K"]);
  for (const x of o) {
    assert.equal(x.kind, "minor");
    assert.deepEqual(x.prices.map((p) => p.price), [90, 80, 75, 70, 65, 60]);
    assert.ok(x.prices.every((p) => p.action !== null && p.reason === null && p.cost === null));
  }
});

test("offers: regionals float for 2 x par; with no minor and too little cash they are par-only with every value", () => {
  const reg = offers(load("concession-regional"));
  assert.ok(reg.length > 0 && reg.every((x) => x.kind === "regional"));
  assert.ok(reg[0]!.prices.every((p) => p.cost === p.price * 2));
  const only = offers(load("concession-paronly"));
  assert.ok(only.length > 0 && only.every((x) => x.kind === "par_only"));
  assert.ok(only.every((x) => x.prices.every((p) => p.action !== null && p.cost === null)));
  const mixed = offers(load("concession-minor"));
  assert.ok(mixed.some((x) => x.kind === "minor"));
});

test("a price the prompt does not offer is dimmed with a reason (cash, else not possible now)", () => {
  const g = load("concession-regional");
  const cash = g.state.players.find((p) => p.id === g.viewer)!.cash;
  g.state.prompt.actions = g.state.prompt.actions.filter((a) => !(a.corporation === "LNWR" && parPrice(a.share_price) === 90));
  g.state.players.find((p) => p.id === g.viewer)!.cash = 170;
  const p90 = offers(g).find((x) => x.corp === "LNWR")!.prices.find((p) => p.price === 90)!;
  assert.equal(p90.action, null);
  assert.equal(p90.reason, "cash");
  g.state.players.find((p) => p.id === g.viewer)!.cash = cash;
  assert.equal(offers(g).find((x) => x.corp === "LNWR")!.prices.find((p) => p.price === 90)!.reason, "now");
});

test("order: nothing chosen is locked; corporation and price send exactly the offered action", () => {
  for (const name of ["concession", "concession-regional", "concession-paronly", "concession-minor"]) {
    const g = load(name);
    const sent: unknown[] = [];
    const idle = orderFor(g, emptySelection(), null, (a) => sent.push(a))!;
    assert.equal(idle.state, "invalid", name);
    idle.onConfirm();
    assert.equal(sent.length, 0, `${name}: an unchosen order sent something`);
    let checked = 0;
    for (const o of offers(g)) for (const pr of o.prices) {
      if (!pr.action) continue;
      const spec = orderFor(g, { corp: o.corp, price: pr.price, city: null }, null, (a) => sent.push(a))!;
      assert.equal(spec.state, "preview");
      spec.onConfirm();
      assert.deepEqual(sent.at(-1), pr.action, `${name} ${o.corp} ${pr.price}`);
      checked++;
    }
    assert.ok(checked > 0, name);
  }
});

test("a single offer is chosen already; with several the player must choose", () => {
  const g = load("concession");
  assert.equal(effectiveSelection(g, emptySelection(), null).corp, null);
  g.state.prompt.actions = g.state.prompt.actions.filter((a) => a.corporation === "C");
  assert.equal(effectiveSelection(g, emptySelection(), null).corp, "C");
  assert.match(sentenceFor(g, emptySelection(), null).text, /C/);
});

test("the sentence names minor or regional, the par value and the confirm word", () => {
  const minor = sentenceFor(load("concession"), { corp: "B", price: 80, city: null }, null);
  assert.match(minor.text, /Minor B/);
  assert.match(minor.text, /£80/);
  const regional = sentenceFor(load("concession-regional"), { corp: "LNWR", price: 70, city: null }, null);
  assert.match(regional.text, /Regional LNWR/);
  const only = sentenceFor(load("concession-paronly"), { corp: "GWR", price: 60, city: null }, null);
  assert.match(only.text, /Regional GWR/);
  assert.notEqual(only.confirm, minor.confirm);
});

test("claims: the panel's steps leave the generic bar when claimed", () => {
  const g = load("concession");
  const claims = createClaims();
  assert.ok(genericModel(g, claims).count > 0);
  claims.claim("Concession", "par");
  assert.equal(genericModel(g, claims).count, 0);
});

test("home token: every target has hex, name and zone with price; single target is chosen already", () => {
  const g = load("home-token");
  const t = homeTargets(g, map);
  assert.equal(t.length, g.state.prompt.actions.length);
  assert.ok(t.every((x) => x.name && x.zone && x.zoneInfo && x.hex === hexOfCity(x.city)));
  assert.equal(effectiveSelection(g, emptySelection(), map).city, null);
  const one = homeTargets(g, null);
  assert.ok(one.every((x) => x.name === null && x.zoneInfo === null), "without map data only the hex id is known");
  const first = t[0]!;
  const s = sentenceFor(g, { corp: null, price: null, city: first.city }, map);
  assert.equal(s.action, first.action);
  assert.match(s.text, new RegExp(first.name!));
  assert.match(s.text, new RegExp(`Zone ${first.zone}`));
  g.state.prompt.actions = [first.action];
  assert.equal(effectiveSelection(g, emptySelection(), map).city, first.city);
  assert.equal(orderFor(g, emptySelection(), map, () => {})!.state, "preview");
});

test("home token: only the viewer sees targets; the others see who executes the concession", () => {
  const g = load("home-token");
  g.state.prompt.viewer_to_act = false;
  assert.equal(homeTargets(g, map).length, 0);
  assert.equal(orderFor(g, emptySelection(), map, () => {}), null);
  const text = textOf(ConcessionPanel(g, emptySelection(), map, noop, themes[0]!));
  assert.match(text, /führt die 1\. Konzession aus/);
});

test("panel DOM: ladder with ten rows, aria-current on the running one; cards and price buttons for the offers", () => {
  const g = load("concession");
  const tree = ConcessionPanel(g, { corp: "B", price: null, city: null }, null, noop, themes[0]!);
  const rows = find(tree, (n) => n.tag === "li" && n.attrs["data-step"] !== undefined);
  assert.equal(rows.length, 10);
  assert.equal(rows.filter((r) => r.attrs["aria-current"] === "step").length, 1);
  assert.equal(find(tree, (n) => n.attrs.class === "concession-card").length, 4);
  const buttons = find(tree, (n) => n.attrs.class === "concession-price");
  assert.equal(buttons.length, 6);
  assert.equal(find(tree, (n) => n.tag === "li" && n.attrs["data-zone"] !== undefined).length, 8);
  const calls: string[] = [];
  const t2 = ConcessionPanel(g, { corp: "B", price: null, city: null }, null, { onCorp: (c) => calls.push(`corp ${c}`), onPrice: (c, p) => calls.push(`price ${c} ${p}`), onCity: () => {} }, themes[0]!);
  find(t2, (n) => n.attrs.class === "concession-price")[2]!.on.click!(new Event("click"));
  find(t2, (n) => n.attrs.class === "concession-card")[1]!.on.click!(new Event("click"));
  assert.deepEqual(calls, ["price B 75", "corp C"]);
});

test("panel DOM: dimmed price buttons are disabled with the reason", () => {
  const g = load("concession-paronly");
  g.state.prompt.actions = g.state.prompt.actions.filter((a) => !(a.corporation === "GWR" && parPrice(a.share_price) === 90));
  const tree = ConcessionPanel(g, { corp: "GWR", price: null, city: null }, null, noop, themes[0]!);
  const b90 = find(tree, (n) => n.attrs.class === "concession-price" && n.attrs["data-price"] === "90")[0]!;
  assert.equal(b90.attrs.disabled, "");
  assert.match(textOf(b90), /Kasse reicht nicht/);
});

test("panel DOM: the home token step lists one button per target with zone and price", () => {
  const g = load("home-token");
  const tree = ConcessionPanel(g, emptySelection(), map, noop, themes[0]!);
  const targets = find(tree, (n) => n.attrs.class === "concession-target");
  assert.equal(targets.length, 62);
  assert.ok(targets.every((b) => /Zone [A-Z]+, £\d+/.test(textOf(b))));
});
