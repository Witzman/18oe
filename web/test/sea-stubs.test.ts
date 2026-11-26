// #444: a port stub in a sea hex starts on a side that borders land (render/sea-stubs.ts). Pure data; the second part
// runs the rule over the real map (fixtures/map-tiles.json, the hexes with their tile parts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { landSide, landSideStub, landSideStubs, sideDistance } from "../render/sea-stubs.ts";
import type { MapHex } from "../render/mapdata.ts";

const hex = (id: string, extra: Partial<MapHex>): MapHex =>
  ({ id, x: 0, y: 0, kind: "land", neighbors: [null, null, null, null, null, null], ...extra }) as MapHex;
const stub = (edge: number) => ({ paths: [{ a: { edge }, b: { node: 0 }, terminal: true }], junction: 0 });

// K36 as in the real map: stub on side 2 (empty sea J35), Amsterdam L37 on side 5
const world = () => [
  hex("K36", { kind: "sea", neighbors: ["L35", "K34", "J35", "J37", "K38", "L37"], ...stub(2) }),
  hex("J35", { kind: "sea" }),
  hex("L37", { kind: "land", icons: [{ image: "/icons/18_oe/offshore_docks.svg", name: "offshore_docks" }] }),
  hex("L35", { kind: "sea" }), hex("K34", { kind: "sea" }), hex("J37", { kind: "sea" }), hex("K38", { kind: "sea" }),
];

test("a stub facing empty sea moves to the side of the land neighbour", () => {
  const out = landSideStubs(world()).find((h) => h.id === "K36")!;
  assert.deepEqual(out.paths, [{ a: { edge: 5 }, b: { node: 0 }, terminal: true }]);
});

test("the input is not changed and a hex that needs nothing is returned as it is", () => {
  const w = world();
  landSideStubs(w);
  assert.deepEqual(w[0]!.paths, [{ a: { edge: 2 }, b: { node: 0 }, terminal: true }]);
  const ok = hex("S", { kind: "sea", neighbors: ["L", null, null, null, null, null], ...stub(0) });
  const land = hex("L", { kind: "land" });
  const byId = new Map([ok, land].map((h) => [h.id, h]));
  assert.equal(landSideStub(ok, byId), ok);
});

test("a port hex next door is open water too: the stub moves (H49 beside G48)", () => {
  const w = world();
  const next = w.find((h) => h.id === "J35")!;
  next.paths = [{ a: { edge: 0 }, b: { node: 0 }, terminal: true }];
  next.junction = 0;
  const out = landSideStubs(w).find((h) => h.id === "K36")!;
  assert.deepEqual(out.paths, [{ a: { edge: 5 }, b: { node: 0 }, terminal: true }]);
});

test("a ferry line next to the stub is not open water: the stub stays (G30)", () => {
  const w = world();
  const line = w.find((h) => h.id === "J35")!;
  line.paths = [{ a: { edge: 0 }, b: { edge: 3 } }];
  const out = landSideStubs(w).find((h) => h.id === "K36")!;
  assert.deepEqual(out.paths, [{ a: { edge: 2 }, b: { node: 0 }, terminal: true }]);
});

test("offshore docks decide between several land sides; without them the nearest side wins", () => {
  const byId = (hs: MapHex[]) => new Map(hs.map((h) => [h.id, h]));
  const h = hex("H49", { kind: "sea", neighbors: ["A", "B", "E", "C", "D", "F"], ...stub(2) });
  const land = (id: string, docks = false) => hex(id, { icons: docks ? [{ image: "/icons/18_oe/offshore_docks.svg", name: "offshore_docks" }] : undefined });
  const empty = hex("E", { kind: "sea" });
  assert.equal(landSide(h, 2, byId([h, land("A"), land("B"), empty, land("C"), land("D"), land("F", true)])), 5);
  // no docks: sides 0, 1, 3, 4, 5 are land, side 2 is current: 1 and 3 tie, the lower side wins
  assert.equal(landSide(h, 2, byId([h, land("A"), land("B"), empty, land("C"), land("D"), land("F")])), 1);
  // no land side: unchanged
  const lone = hex("L", { kind: "sea", neighbors: ["E", "E", "E", "E", "E", "E"], ...stub(1) });
  assert.equal(landSide(lone, 1, byId([lone, empty])), 1);
});

test("sideDistance goes round the hex", () => {
  assert.equal(sideDistance(0, 5), 1);
  assert.equal(sideDistance(1, 4), 3);
  assert.equal(sideDistance(2, 2), 0);
});

test("on the real map every moved stub borders land and K36 is Amsterdam's", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const tiles = JSON.parse(readFileSync(join(here, "fixtures", "map-tiles.json"), "utf8"));
  const geometry = JSON.parse(readFileSync(join(here, "fixtures", "map-geometry.json"), "utf8"));
  const parts = new Map<string, Partial<MapHex>>(tiles.hexes.map((h: MapHex) => [h.id, h]));
  const hexes: MapHex[] = geometry.hexes.map((h: MapHex) => ({ ...h, ...(parts.get(h.id) ?? {}) }));
  const byId = new Map(hexes.map((h) => [h.id, h]));
  const out = landSideStubs(hexes);
  const k36 = out.find((h) => h.id === "K36")!;
  assert.deepEqual(k36.paths, [{ a: { edge: 5 }, b: { node: 0 }, terminal: true }]);
  let moved = 0;
  for (const h of out) {
    const before = byId.get(h.id)!;
    if (h === before) continue;
    moved++;
    for (const p of h.paths ?? []) {
      const e = "edge" in p.a ? p.a.edge : (p.b as { edge: number }).edge;
      assert.notEqual(byId.get(h.neighbors[e]!)?.kind, "sea", `${h.id} stub side ${e} must border land`);
    }
  }
  assert.ok(moved >= 1 && moved <= 12, `moved ${moved} sea hexes`);
});

test("the stub ends in an arrow in the middle of the hex, pointing in from the land side", async () => {
  const { hexFrame, tileGeometry } = await import("../render/track-axes.ts");
  const { junctionArrows } = await import("../render/stones.ts");
  const here = dirname(fileURLToPath(import.meta.url));
  const tiles = JSON.parse(readFileSync(join(here, "fixtures", "map-tiles.json"), "utf8"));
  const frame = hexFrame(tiles.layout.edge_vectors);
  const k36 = landSideStubs(world()).find((h) => h.id === "K36")!;
  const geom = tileGeometry(k36, 0, frame);
  const [arrow] = junctionArrows(geom.nodes, geom.axes, 0.3, 0.26);
  assert.ok(arrow, "one arrow for one stub");
  const [tx, ty, ax, ay, bx, by] = arrow!;
  const centre = geom.nodes.find((n) => n.kind === "junction")!.pos;
  assert.ok(Math.hypot(tx! - centre.x, ty! - centre.y) < 1e-9, "the tip is at the junction");
  // the base lies towards side 5, 0.3 behind the tip, 0.26 wide
  const u = frame.unit[5]!;
  const mid = { x: (ax! + bx!) / 2, y: (ay! + by!) / 2 };
  assert.ok(Math.hypot(mid.x - (tx! + u.x * 0.3), mid.y - (ty! + u.y * 0.3)) < 0.02, "the base is towards the land side");
  assert.ok(Math.abs(Math.hypot(ax! - bx!, ay! - by!) - 0.26) < 1e-9);
  assert.deepEqual(junctionArrows(geom.nodes, [], 0.3, 0.26), [], "no stub, no arrow");
});

// Tiles 80-83 and 544-546 branch at a junction too: their paths run through, nothing ends there.
test("a track junction on land gets no arrow", async () => {
  const { hexFrame, tileGeometry } = await import("../render/track-axes.ts");
  const { junctionArrows } = await import("../render/stones.ts");
  const here = dirname(fileURLToPath(import.meta.url));
  const tiles = JSON.parse(readFileSync(join(here, "fixtures", "map-tiles.json"), "utf8"));
  const frame = hexFrame(tiles.layout.edge_vectors);
  const tile80 = { junction: 0, paths: [0, 1, 2].map((edge) => ({ a: { edge }, b: { node: 0 } })) };
  const geom = tileGeometry(tile80, 0, frame);
  assert.equal(geom.nodes.filter((n) => n.kind === "junction").length, 1);
  assert.deepEqual(junctionArrows(geom.nodes, geom.axes, 0.3, 0.26), []);
});
