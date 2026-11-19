// Run bands (#155): the axis of a proposed run over straight, curved and city tiles is continuous, the
// zoom stages show what the owner decided, two trains are offset sideways.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { Z1_FROM, Z2_FROM, zoomStage } from "../render/camera.ts";
import { MAX_STEP, axisChain, offsetPoints, parseNode, routeLine, runOffsets, runVisibility, type RunWorld } from "../render/runs.ts";
import { bandWidth, effectiveWidth } from "../render/layers/runs.ts";
import { renderTheme } from "../render/theme.ts";
import { themes, DEFAULT_THEME_ID } from "../themes/index.ts";
import { hexFrame, tileGeometry, type TileParts, type Vec } from "../render/track-axes.ts";

const fx = JSON.parse(readFileSync(new URL("./fixtures/map-tiles.json", import.meta.url), "utf8")) as {
  layout: { edge_vectors: [number, number][] };
  tiles: Record<string, TileParts>;
};
const frame = hexFrame(fx.layout.edge_vectors);
const dist = (p: Vec, q: Vec) => Math.hypot(p.x - q.x, p.y - q.y);

/** A row of hexes walked along the given exit edges, each with tile parts (rotation 0, edges as the test sets them). */
function world(exits: number[], parts: TileParts[]): RunWorld & { ids: string[] } {
  const ids = parts.map((_, i) => `H${i}`);
  const origin = new Map<string, Vec>([["H0", { x: 0, y: 0 }]]);
  const nb = new Map<string, (string | null)[]>(ids.map((id) => [id, Array(6).fill(null)]));
  exits.forEach((e, i) => {
    const v = fx.layout.edge_vectors[e]!, o = origin.get(ids[i]!)!;
    origin.set(ids[i + 1]!, { x: o.x + v[0], y: o.y + v[1] });
    nb.get(ids[i]!)![e] = ids[i + 1]!;
    nb.get(ids[i + 1]!)![(e + 3) % 6] = ids[i]!;
  });
  const geoms = new Map(ids.map((id, i) => [id, tileGeometry(parts[i]!, 0, frame)] as const));
  return { ids, neighbors: (h) => nb.get(h), geometry: (h) => geoms.get(h) ?? null, origin: (h) => origin.get(h) ?? null };
}

// straight (tile 9), wide arc (tile 8: 0 -> 2), sharp arc (tile 7: 0 -> 1), a through town (tile 4), city ends (tile 57 shape)
const cityEnd = (edge: number): TileParts => ({ cities: [{ node: 0, slots: 1, revenue: 20 }], paths: [{ a: { edge }, b: { node: 0 } }] });
const straight = (a: number, b: number): TileParts => ({ paths: [{ a: { edge: a }, b: { edge: b } }] });
const townThrough = (a: number, b: number): TileParts => ({
  towns: [{ node: 0, revenue: 10 }], paths: [{ a: { edge: a }, b: { node: 0 } }, { a: { node: 0 }, b: { edge: b } }],
});

/** Exit edges 4,4,5,5 (straight, then a bend towards 5): hexes H0 (city) .. H4 (city). */
function bendRow() {
  // H0 city -> exit 4; H1 straight enters 1 leaves 4; H2 wide arc enters 1 leaves 5 (distance 2: 1 -> 5 is 2 steps);
  // H3 through town enters 2 leaves 5; H4 city, enters 2
  return world([4, 4, 5, 5], [cityEnd(4), straight(1, 4), straight(1, 5), townThrough(2, 5), cityEnd(2)]);
}

test("parseNode reads hex and node index", () => {
  assert.deepEqual(parseNode("H21-0"), { hex: "H21", node: 0 });
  assert.equal(parseNode("nonsense"), null);
});

test("the axis over straight, arc, through-town and city tiles is continuous from stop to stop", () => {
  const w = bendRow();
  const line = routeLine({ train: "2-0", revenue: 40, connections: [["H0", "H1", "H2", "H3", "H4"]], nodes: ["H0-0", "H4-0"] }, w);
  assert.deepEqual(line.unresolved, []);
  assert.deepEqual(line.breaks, []);
  assert.equal(line.hexes.length, line.points.length);
  assert.deepEqual([...new Set(line.hexes)], ["H0", "H1", "H2", "H3", "H4"]);
  assert.ok(line.points.length > 20);
  for (let i = 1; i < line.points.length; i++) {
    assert.ok(dist(line.points[i - 1]!, line.points[i]!) <= MAX_STEP + 1e-9, `jump at point ${i}: ${dist(line.points[i - 1]!, line.points[i]!)}`);
  }
  // starts at the first stop, ends at the last
  assert.equal(line.stops.length, 2);
  assert.ok(dist(line.points[0]!, line.stops[0]!.at) < 1e-9);
  assert.ok(dist(line.points[line.points.length - 1]!, line.stops[1]!.at) < 1e-9);
});

test("two chains joined at a stop make one axis; a ferry-like hex of paths only is followed too", () => {
  const w = world([4, 4], [cityEnd(4), { cities: [{ node: 0, slots: 1, revenue: 20 }], paths: [{ a: { edge: 1 }, b: { node: 0 } }, { a: { node: 0 }, b: { edge: 4 } }] }, cityEnd(1)]);
  const line = routeLine({ train: "3-0", revenue: 50, connections: [["H0", "H1"], ["H1", "H2"]], nodes: ["H0-0", "H1-0", "H2-0"] }, w);
  assert.deepEqual(line.unresolved, []);
  assert.deepEqual(line.breaks, []);
  for (let i = 1; i < line.points.length; i++) assert.ok(dist(line.points[i - 1]!, line.points[i]!) <= MAX_STEP + 1e-9);
  assert.equal(line.stops.length, 3);
});

test("a hex without tile data is listed and joined by a straight break, not silently skipped", () => {
  const w = bendRow();
  const holey: RunWorld = { ...w, geometry: (h) => (h === "H2" ? null : w.geometry(h)) };
  const line = routeLine({ train: "2-0", revenue: 40, connections: [["H0", "H1", "H2", "H3", "H4"]], nodes: ["H0-0", "H4-0"] }, holey);
  assert.deepEqual(line.unresolved, ["H2"]);
  assert.equal(line.breaks.length, 1);
});

test("axisChain finds the through-town halves and refuses unconnected ends", () => {
  const g = tileGeometry(townThrough(2, 5), 0, frame);
  const chain = axisChain(g, { edge: 2 }, { edge: 5 })!;
  assert.equal(chain.length, 2);
  assert.equal(axisChain(g, { edge: 0 }, { edge: 5 }), null);
});

test("zoom stages: band at every zoom, rings from Z1, shields only at Z2", () => {
  const at = (zoom: number) => runVisibility(zoomStage(zoom));
  assert.deepEqual(at(Z1_FROM - 1), { band: true, rings: false, shields: false });
  assert.deepEqual(at(Z1_FROM), { band: true, rings: true, shields: false });
  assert.deepEqual(at(Z2_FROM), { band: true, rings: true, shields: false });
  assert.deepEqual(at(Z2_FROM + 1), { band: true, rings: true, shields: true });
});

test("two trains are offset sideways, symmetric about the track, by the gap", () => {
  assert.deepEqual(runOffsets(1, 0.2), [0]);
  assert.deepEqual(runOffsets(2, 0.2), [-0.1, 0.1]);
  assert.deepEqual(runOffsets(3, 0.2).map((x) => Math.round(x * 100) / 100), [-0.2, 0, 0.2]);
  const w = bendRow();
  const line = routeLine({ train: "2-0", revenue: 40, connections: [["H0", "H1", "H2", "H3", "H4"]], nodes: ["H0-0", "H4-0"] }, w);
  const [lo, hi] = runOffsets(2, 0.2).map((d) => offsetPoints(line.points, d, line.breaks));
  assert.equal(lo!.length, line.points.length);
  // the two lines are 0.2 apart on the straight stretch (middle of H1), and every point of each moved 0.1 off the axis
  const mid = Math.floor(line.points.length / 4);
  assert.ok(Math.abs(dist(lo![mid]!, hi![mid]!) - 0.2) < 1e-6);
  assert.ok(Math.abs(dist(lo![mid]!, line.points[mid]!) - 0.1) < 1e-6);
  // an offset line stays continuous too (no jump larger than a step plus the bend's stretch)
  for (let i = 1; i < hi!.length; i++) assert.ok(dist(hi![i - 1]!, hi![i]!) < 2 * MAX_STEP);
});

test("band width: a token, narrower for several trains, never thinner than runMinPx on the screen", () => {
  const theme = renderTheme({ theme: themes.find((t) => t.id === DEFAULT_THEME_ID) ?? themes[0]!, tileStyle: "full" });
  assert.equal(bandWidth(theme, 1), theme.track.runWidth);
  assert.ok(bandWidth(theme, 2) < theme.track.runWidth);
  assert.equal(effectiveWidth(0.3, 100, 3), 0.3);
  assert.ok(Math.abs(effectiveWidth(0.3, 5, 3) * 5 - 3) < 1e-9, "at zoom 5 the band keeps 3 px");
});
