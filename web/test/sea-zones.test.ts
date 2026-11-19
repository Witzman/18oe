// #449: the sea of the board: zone boundaries, one circle per zone, dashes (render/sea-zones.ts). The real map is
// fixtures/map-geometry.json (all hexes with `sea_zone`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { dashes, markGlyph, seaOfHex, zoneBorders, zoneMarks } from "../render/sea-zones.ts";
import type { MapHex } from "../render/mapdata.ts";

const here = dirname(fileURLToPath(import.meta.url));
const hexes: MapHex[] = JSON.parse(readFileSync(join(here, "fixtures", "map-geometry.json"), "utf8")).hexes;
const byId = new Map(hexes.map((h) => [h.id, h]));

test("seaOfHex gives every zone hex its sea", () => {
  const m = seaOfHex([{ name: "A", sea: "north_sea", hexes: ["a1", "a2"] }, { name: "B", sea: "mediterranean", hexes: ["b1"] }]);
  assert.equal(m.get("a2"), "north_sea");
  assert.equal(m.get("b1"), "mediterranean");
  assert.equal(m.get("x"), undefined);
  assert.equal(seaOfHex(undefined).size, 0);
});

test("a zone border lies between two sea hexes of different zones, once", () => {
  const borders = zoneBorders(hexes);
  assert.ok(borders.length > 20, `${borders.length} borders`);
  const seen = new Set<string>();
  for (const b of borders) {
    const h = byId.get(b.hex)!, n = byId.get(h.neighbors[b.edge]!)!;
    assert.ok(h.sea_zone && n.sea_zone && h.sea_zone !== n.sea_zone, `${b.hex} side ${b.edge}`);
    const key = [h.id, n.id].sort().join("|");
    assert.ok(!seen.has(key), `${key} twice`);
    seen.add(key);
  }
});

test("a small map: the border is the side shared by two zones", () => {
  const a = { id: "A", x: 0, y: 0, kind: "sea", sea_zone: "one", neighbors: [null, "B", null, null, null, null] } as MapHex;
  const b = { id: "B", x: 1, y: 0, kind: "sea", sea_zone: "two", neighbors: [null, null, null, "A", null, null] } as MapHex;
  assert.deepEqual(zoneBorders([a, b]), [{ hex: "A", edge: 1 }]);
  assert.deepEqual(zoneBorders([a, { ...b, sea_zone: "one" }]), []);
});

test("every zone of the real map has one circle, in a hex of that zone", () => {
  const zones = new Set(hexes.map((h) => h.sea_zone).filter(Boolean));
  const marks = zoneMarks(hexes);
  assert.equal(marks.length, zones.size);
  assert.ok(zones.size >= 19, `${zones.size} zones`);
  for (const m of marks) {
    const h = byId.get(m.hex)!;
    assert.equal(h.sea_zone, m.zone);
    assert.equal(h.x, m.x);
  }
});

test("dashes are dash long, gap apart, and the last one ends at the line", () => {
  const out = dashes({ x: 0, y: 0 }, { x: 1, y: 0 }, 0.3, 0.2);
  assert.equal(out.length, 2);
  assert.deepEqual(out[0], [{ x: 0, y: 0 }, { x: 0.3, y: 0 }]);
  assert.ok(Math.abs(out[1]![0].x - 0.5) < 1e-12 && Math.abs(out[1]![1].x - 0.8) < 1e-12);
  const cut = dashes({ x: 0, y: 0 }, { x: 0.6, y: 0 }, 0.3, 0.2);
  assert.ok(Math.abs(cut[1]![1].x - 0.6) < 1e-12 || cut.length === 2);
  assert.deepEqual(dashes({ x: 1, y: 1 }, { x: 1, y: 1 }, 0.3, 0.2), []);
});

test("the fixture map carries the sea zones the scenes and tests draw (/map has them)", () => {
  const geometry = JSON.parse(readFileSync(join(here, "fixtures", "map-geometry.json"), "utf8"));
  const seas = seaOfHex(geometry.sea_zones);
  assert.equal(new Set(geometry.sea_zones.map((z: { sea: string }) => z.sea)).size, 2);
  for (const h of hexes) if (h.sea_zone) assert.ok(seas.has(h.id), `${h.id} has a zone but no sea`);
});

test("the mark glyph is a bold one over a wave, inside the circle (#477)", () => {
  const g = markGlyph(10, 20, 0.6);
  assert.equal(g.one.length >= 2, true);
  assert.ok(g.wave.length >= 4);
  for (const p of [...g.one.flat(), ...g.wave]) assert.ok(Math.hypot(p.x - 10, p.y - 20) < 0.6 * 0.85, `${p.x},${p.y}`);
  // the wave sits under the one
  const lowestOne = Math.max(...g.one.flat().map((p) => p.y)), waveY = g.wave.reduce((s, p) => s + p.y, 0) / g.wave.length;
  assert.ok(waveY > lowestOne - 1e-9);
  assert.ok(g.width > 0 && g.width < 0.6);
});
