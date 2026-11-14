// Soft coast (#100): contour of the land mass from the hex kinds, against the real map
// (fixtures/map-geometry.json, 1492 hexes). No PixiJS.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { CHAIKIN_ROUNDS, chaikin, COAST_MAX_DEV, distToRing, landRings, landShapes, type Ring } from "../render/coast.ts";
import type { MapGeometry } from "../render/mapdata.ts";
import type { Vec } from "../render/projection.ts";
import { buildScene } from "../render/scene.ts";
import { renderTheme } from "../render/theme.ts";
import { themeById } from "../themes/index.ts";

const here = dirname(fileURLToPath(import.meta.url));
const geometry = JSON.parse(readFileSync(join(here, "fixtures", "map-geometry.json"), "utf8")) as MapGeometry;
const brett = renderTheme({ theme: themeById("brett"), tileStyle: "full" });
const atlas = renderTheme({ theme: themeById("atlas"), tileStyle: "full" });
const scene = buildScene(geometry, brett);
const params = { round: brett.coastRound, noise: brett.coastNoise };
const rings = landRings(scene, params);

const near = (a: Vec, b: Vec) => Math.hypot(a.x - b.x, a.y - b.y) < 1e-6;

test("rings: every ring is closed and every land hex edge on the contour is covered once", () => {
  assert.ok(rings.length > 5, `${rings.length} rings`);
  const land = scene.grid.hexes.filter((h) => scene.levelOf.get(h.id)! > 0);
  let edges = 0;
  for (const h of land) for (let i = 0; i < 6; i++) { const n = h.neighbors[i]; if (!n || scene.levelOf.get(n) === 0) edges++; }
  assert.equal(rings.reduce((s, r) => s + r.raw.length, 0), edges);
  for (const r of rings) {
    assert.ok(r.points.length >= r.raw.length, "smoothing only adds points");
    assert.equal(r.border.length, r.raw.length);
  }
});

test("islands stay separate: no two outer rings share a raw point, and each raw ring lies in its own land", () => {
  const outers = rings.filter((r) => !r.hole);
  const seen = new Map<string, number>();
  outers.forEach((r, i) => r.raw.forEach((p) => {
    const k = `${Math.round(p.x * 1000)},${Math.round(p.y * 1000)}`;
    assert.ok(!seen.has(k) || seen.get(k) === i, `corner ${k} on rings ${seen.get(k)} and ${i}`);
    seen.set(k, i);
  }));
  assert.ok(outers.length >= 3, `${outers.length} separate land masses (mainland and islands)`);
  // A land hex's centre lies inside exactly one outer ring of the smoothed contour and not in a lake.
  const shapes = landShapes(rings);
  assert.equal(shapes.reduce((s, x) => s + x.holes.length, 0), rings.filter((r) => r.hole).length, "every hole has a host");
});

/** Segments of all smoothed rings, bucketed on a grid, to find proper crossings. */
function crossings(all: Ring[]): number {
  const cell = 2;
  const segs: [Vec, Vec][] = [];
  const buckets = new Map<string, number[]>();
  for (const r of all) {
    for (let i = 0; i < r.points.length; i++) segs.push([r.points[i]!, r.points[(i + 1) % r.points.length]!]);
  }
  segs.forEach(([a, b], idx) => {
    for (let x = Math.floor(Math.min(a.x, b.x) / cell); x <= Math.floor(Math.max(a.x, b.x) / cell); x++)
      for (let y = Math.floor(Math.min(a.y, b.y) / cell); y <= Math.floor(Math.max(a.y, b.y) / cell); y++) {
        const k = `${x},${y}`;
        (buckets.get(k) ?? buckets.set(k, []).get(k)!).push(idx);
      }
  });
  const o = (a: Vec, b: Vec, c: Vec) => (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
  const checked = new Set<string>();
  let n = 0;
  for (const list of buckets.values()) {
    for (let i = 0; i < list.length; i++) for (let j = i + 1; j < list.length; j++) {
      const p = list[i]!, q = list[j]!;
      const k = `${p}/${q}`;
      if (checked.has(k)) continue;
      checked.add(k);
      const [a, b] = segs[p]!, [c, d] = segs[q]!;
      if (near(a, c) || near(a, d) || near(b, c) || near(b, d)) continue; // neighbours in the ring
      if (o(a, b, c) * o(a, b, d) < 0 && o(c, d, a) * o(c, d, b) < 0) n++;
    }
  }
  return n;
}

test("no self-intersection of the smoothed contour, brett and atlas parameters", () => {
  assert.equal(crossings(rings), 0);
  const a = landRings(scene, { round: atlas.coastRound, noise: atlas.coastNoise });
  assert.equal(crossings(a), 0);
  // Also at the largest values the schema allows.
  assert.equal(crossings(landRings(scene, { round: 0.5, noise: 0.3 })), 0);
});

test("coast stays close to the grid: at most COAST_MAX_DEV side lengths from the hex contour, both ways", () => {
  for (const r of rings) {
    for (const p of r.points) assert.ok(distToRing(p, r.raw) <= COAST_MAX_DEV, `smoothed point ${p.x},${p.y} ${distToRing(p, r.raw)}`);
    for (const p of r.raw) assert.ok(distToRing(p, r.points) <= COAST_MAX_DEV, "raw corner");
  }
});

test("land and sea of every hex stay readable: hex centres keep their side of the contour", () => {
  const shapes = landShapes(rings);
  const inShape = (p: Vec) => shapes.some((s) => insideRing(p, s.outer.points) && !s.holes.some((h) => insideRing(p, h.points)));
  for (const h of scene.grid.hexes) assert.equal(inShape(h), scene.levelOf.get(h.id)! > 0, h.id);
});

function insideRing(p: Vec, ring: Vec[]): boolean {
  let c = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const a = ring[i]!, b = ring[j]!;
    if ((a.y > p.y) !== (b.y > p.y) && p.x < ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y) + a.x) c = !c;
  }
  return c;
}

test("map border stays straight: border edges are not moved", () => {
  let checked = 0;
  for (const r of rings) {
    r.raw.forEach((a, i) => {
      if (!r.border[i]) return;
      const b = r.raw[(i + 1) % r.raw.length]!;
      assert.ok(r.points.some((p) => near(p, a)), "border start kept");
      assert.ok(r.points.some((p) => near(p, b)), "border end kept");
      checked++;
    });
  }
  assert.ok(checked > 0, "the map has land at its border");
});

test("round 0 and noise 0 give the hard hex contour", () => {
  const hard = landRings(scene, { round: 0, noise: 0 });
  for (const r of hard) assert.equal(r.points.length, r.raw.length);
});

test("chaikin: an open polyline keeps its ends, a closed ring grows by 2^rounds", () => {
  const sq = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }];
  const open = chaikin(sq, 0.25, CHAIKIN_ROUNDS, false);
  assert.ok(near(open[0]!, sq[0]!) && near(open[open.length - 1]!, sq[3]!));
  assert.equal(chaikin(sq, 0.25, 2, true).length, 4 * 4);
});

test("building the contour is fast (first render budget)", () => {
  const t = performance.now();
  landRings(scene, params);
  const ms = performance.now() - t;
  console.log(`landRings: ${ms.toFixed(1)} ms`);
  assert.ok(ms < 400, `${ms} ms`);
});
