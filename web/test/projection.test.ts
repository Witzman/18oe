// Projection and picking (#143, ui-spec 2.2) against the real map: fixtures/map-geometry.json
// is the geometry subset of GET /map for all 1492 hexes (Oe::MapData.build). Heights come from
// the themes. Not covered here: how it looks in a browser (renderer is #44).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { hexHeight, type MapGeometry } from "../render/mapdata.ts";
import {
  apply, buildGrid, depth, fitView, hexAt, insideHex, invert, levelMatrix, mapCenter, pick, pickWithHeight, project,
  screenBounds, topPolygon, unproject, walls, worldCorners, type GridHex, type HexGrid, type Vec, type View,
} from "../render/projection.ts";
import { themeById, themes } from "../themes/index.ts";

const here = dirname(fileURLToPath(import.meta.url));
const map = JSON.parse(readFileSync(join(here, "fixtures", "map-geometry.json"), "utf8")) as MapGeometry;
const brett = themeById("brett").camera;
const hexById = new Map(map.hexes.map((h) => [h.id, h]));

function grid(heightOf: (id: string) => number): HexGrid {
  return buildGrid(map.hexes, map.layout.edge_vectors, heightOf);
}
const flat = grid(() => 0);
const real = grid((id) => hexHeight(hexById.get(id)!, brett));
const center = mapCenter(real);

/** Camera positions (pitch, yaw): top view, both theme cameras, the spec's three, the schema's extremes. */
const CAMERAS: [number, number][] = [[0, 0], [38, -12], [30, -6], [60, 30], [65, -45], [65, 45], [20, 45]];
function view(pitch: number, yaw: number, zoom = 20): View {
  return { pitch, yaw, zoom, panX: 700, panY: 450, centerX: center.x, centerY: center.y };
}

/**
 * Independent check that pick's answer is the first thing the view ray meets: the hit point lies
 * in the hex column at or below its top, and marching down the ray in small height steps from
 * the highest top finds nothing above the hit (ties on an edge, where the ray grazes a top's
 * rim exactly, are accepted either way).
 */
function assertFirstHit(g: HexGrid, v: View, s: Vec, what: string, steps = 2000): GridHex | null {
  const res = pickWithHeight(g, v, s);
  if (!res) {
    for (let i = 0; i <= steps; i++) {
      const z = g.maxZ * (1 - i / steps), h = hexAt(g, unproject(v, s, z));
      assert.ok(!h || h.z < z, `${what}: pick found nothing, but ${h?.id} is hit at ${z}`);
    }
    return null;
  }
  assert.ok(res.z <= res.hex.z + 1e-9 && insideHex(g, res.hex, unproject(v, s, res.z), 1e-6), `${what}: hit point not in ${res.hex.id}`);
  for (let i = 0; i <= steps; i++) {
    const z = g.maxZ * (1 - i / steps);
    if (z <= res.z + 1e-6) break;
    const h = hexAt(g, unproject(v, s, z));
    assert.ok(!h || h.z < z, `${what}: ${h?.id} is hit at ${z}, above ${res.hex.id} at ${res.z}`);
  }
  return res.hex;
}

/** The spec's discrete form (test only, for comparison): test each height level, descending. */
function byLevels(g: HexGrid, v: View, s: Vec): GridHex | null {
  for (const L of g.levels) {
    const h = hexAt(g, unproject(v, s, L));
    if (h && h.z >= L - 1e-12) return h;
  }
  return null;
}

const lerp = (a: Vec, b: Vec, t: number): Vec => ({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t });
const near90 = (g: HexGrid, h: GridHex): Vec[] => worldCorners(g, h).map((c) => lerp(h, c, 0.9));

/** Deterministic pseudo-random numbers (no flaky tests). */
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}

test("fixture is the whole map from /map: 1492 hexes, three kinds, heights from the theme", () => {
  assert.equal(map.hexes.length, 1492);
  assert.deepEqual(new Set(map.hexes.map((h) => h.kind)), new Set(["land", "sea", "offboard"]));
  assert.deepEqual(real.levels, [...new Set([0, brett.heightLand, brett.heightLand + brett.heightHill, brett.heightLand + brett.heightMountain])].sort((a, b) => b - a));
});

test("hex shape from layout.edge_vectors: corners at the side length, neighbours exactly one edge vector away", () => {
  const { shape } = real;
  assert.ok(Math.abs(shape.radius - 1) < 1e-5);
  for (const c of shape.corners) assert.ok(Math.abs(Math.hypot(c.x, c.y) - 1) < 1e-5);
  for (const h of real.hexes) {
    h.neighbors.forEach((nid, i) => {
      if (!nid) return;
      const n = real.byId.get(nid)!;
      assert.ok(Math.hypot(n.x - h.x - shape.edges[i]!.x, n.y - h.y - shape.edges[i]!.y) < 1e-5, `${h.id} edge ${i}`);
    });
  }
});

test("levelMatrix is the spec formula; invert undoes it", () => {
  const r = rng(1);
  for (const [pitch, yaw] of CAMERAS) {
    const v = view(pitch, yaw, 17);
    for (let i = 0; i < 200; i++) {
      const p = { x: r() * 80, y: r() * 52 }, z = r() * 0.5;
      const a = yaw * Math.PI / 180, t = pitch * Math.PI / 180;
      const xr = Math.cos(a) * (p.x - center.x) - Math.sin(a) * (p.y - center.y);
      const yr = Math.sin(a) * (p.x - center.x) + Math.cos(a) * (p.y - center.y);
      const s = project(v, p, z);
      assert.ok(Math.abs(s.x - (v.panX + v.zoom * xr)) < 1e-9);
      assert.ok(Math.abs(s.y - (v.panY + v.zoom * (yr * Math.cos(t) - z * Math.sin(t)))) < 1e-9);
      assert.ok(Math.abs(depth(v, p) - yr) < 1e-9);
      const back = unproject(v, s, z);
      assert.ok(Math.hypot(back.x - p.x, back.y - p.y) < 1e-9);
      const m = levelMatrix(v, z), id = apply(m, apply(invert(m), s));
      assert.ok(Math.hypot(id.x - s.x, id.y - s.y) < 1e-9);
    }
  }
  assert.throws(() => invert(levelMatrix(view(90, 0), 0)), /not invertible/);
});

test("hexAt: every centre and 90 % towards every corner is its own hex; off the map is null; agrees with a linear scan", () => {
  for (const h of flat.hexes) {
    assert.equal(hexAt(flat, h)?.id, h.id);
    for (const p of near90(flat, h)) assert.equal(hexAt(flat, p)?.id, h.id);
  }
  assert.equal(hexAt(flat, { x: -5, y: -5 }), null);
  assert.equal(hexAt(flat, { x: 200, y: 20 }), null);
  const r = rng(2);
  for (let i = 0; i < 3000; i++) {
    const p = { x: -2 + r() * 82, y: -2 + r() * 54 };
    const scan = flat.hexes.find((h) => insideHex(flat, h, p)) ?? null;
    assert.equal(hexAt(flat, p)?.id ?? null, scan?.id ?? null);
  }
});

test("roundtrip on a flat map: centre and six points at 90 % to the corners pick the hex, every camera", () => {
  for (const [pitch, yaw] of CAMERAS) {
    const v = view(pitch, yaw);
    for (const h of flat.hexes) {
      assert.equal(pick(flat, v, project(v, h, 0))?.id, h.id, `${h.id} at ${pitch}/${yaw}`);
      for (const p of near90(flat, h)) assert.equal(pick(flat, v, project(v, p, 0))?.id, h.id);
    }
  }
});

test("roundtrip with real heights: the top's centre and 90 % corner points pick the hex unless a nearer, higher hex covers them", (t) => {
  for (const [pitch, yaw] of CAMERAS) {
    const v = view(pitch, yaw);
    let covered = 0, coveredCentres = 0;
    for (const h of real.hexes) {
      const points = [h, ...near90(real, h)];
      points.forEach((p, i) => {
        const s = project(v, p, h.z);
        const got = pick(real, v, s);
        if (got?.id === h.id) return;
        // Not the hex itself: must be an occluder (reference agrees, higher and nearer the viewer).
        assert.ok(got, `${h.id} point ${i} at ${pitch}/${yaw}: nothing`);
        assertFirstHit(real, v, s, `${h.id} point ${i} at ${pitch}/${yaw}`);
        assert.ok(got.z > h.z && depth(v, got) > depth(v, h), `${got.id} covers ${h.id}`);
        covered++;
        if (i === 0) coveredCentres++;
      });
    }
    if (pitch === 0) assert.equal(covered, 0);
    t.diagnostic(`pitch ${pitch} yaw ${yaw}: ${coveredCentres} of ${real.hexes.length} centres and ${covered} of ${real.hexes.length * 7} test points covered by a nearer, higher hex`);
  }
});

test("border of two hexes: the shared edge's midpoint, nudged to either side, picks that side", () => {
  for (const [pitch, yaw] of CAMERAS) {
    const v = view(pitch, yaw);
    for (const g of [flat, real]) {
      for (const h of g.hexes) {
        h.neighbors.forEach((nid, i) => {
          const n = nid ? g.byId.get(nid)! : null;
          if (!n || n.z !== h.z || h.id > n.id) return;
          const e = g.shape.edges[i]!;
          const mid = { x: h.x + e.x / 2, y: h.y + e.y / 2 };
          if (g === flat) assert.ok([h.id, n.id].includes(pick(g, v, project(v, mid, 0))?.id ?? ""));
          for (const [side, sign] of [[h, -1], [n, 1]] as const) {
            const s = project(v, { x: mid.x + sign * 1e-6 * e.x, y: mid.y + sign * 1e-6 * e.y }, h.z);
            const got = pick(g, v, s);
            if (g === flat) assert.equal(got?.id, side.id);
            else if (got?.id !== side.id) assertFirstHit(g, v, s, `${side.id} near edge ${i} of ${h.id}`);
          }
        });
      }
    }
  }
});

test("front walls: visible only towards lower neighbours, never at pitch 0; a point in a wall picks the wall's hex unless covered", (t) => {
  for (const h of real.hexes) assert.deepEqual(walls(real, view(0, 0), h), []);
  for (const [pitch, yaw] of CAMERAS.filter(([p]) => p > 0)) {
    const v = view(pitch, yaw);
    let count = 0, own = 0;
    for (const h of real.hexes) {
      for (const w of walls(real, v, h)) {
        count++;
        const n = w.hex.neighbors[w.edge];
        assert.ok(w.bottom < h.z && (n === null || real.byId.get(n!)!.z === w.bottom));
        assert.ok(w.polygon[2]!.y > w.polygon[1]!.y, "foot below the top on screen");
        const [a, b, c, d] = w.polygon as [Vec, Vec, Vec, Vec];
        const mid = { x: (a.x + b.x + c.x + d.x) / 4, y: (a.y + b.y + c.y + d.y) / 4 };
        const got = pick(real, v, mid);
        if (got?.id === h.id) own++;
        else {
          assertFirstHit(real, v, mid, `wall ${h.id}/${w.edge} at ${pitch}/${yaw}`);
          assert.ok(got && got.z > w.bottom && depth(v, got) > depth(v, h));
        }
      }
    }
    assert.ok(count > 0 && own > 0.9 * count, `${own} of ${count}`);
    t.diagnostic(`pitch ${pitch} yaw ${yaw}: ${count} visible walls, ${own} wall midpoints pick their own hex, ${count - own} covered by a nearer, higher hex`);
  }
});

test("occlusion: a raised hex covers the centre of the hex behind it", () => {
  // Hex in the middle of the map; "behind" = the neighbour whose edge points up the screen.
  const v = view(38, -12);
  const tall = flat.hexes.find((h) => h.neighbors.every(Boolean) && Math.hypot(h.x - center.x, h.y - center.y) < 3)!;
  const g = grid((id) => (id === tall.id ? 2 : 0));
  const m = levelMatrix(v, 0);
  const behind = tall.neighbors
    .map((id, i) => ({ id: id!, up: m.b * g.shape.edges[i]!.x + m.d * g.shape.edges[i]!.y }))
    .sort((p, q) => p.up - q.up)[0]!.id;
  const b = g.byId.get(behind)!;
  assert.equal(pick(g, v, project(v, b, 0))?.id, tall.id);
  assert.equal(pick(g, view(0, 0), project(view(0, 0), b, 0))?.id, behind, "seen from above nothing is covered");
  assert.equal(pick(g, v, project(v, g.byId.get(tall.id)!, 2))?.id, tall.id);
});

test("random screen points: pick is the first hit along the ray; the discrete-level form is measured against it", (t) => {
  const r = rng(3);
  for (const [pitch, yaw] of CAMERAS) {
    const v = view(pitch, yaw);
    const b = screenBounds(real, v);
    let levelMisses = 0;
    const N = 400;
    for (let i = 0; i < N; i++) {
      const s = { x: b.minX + r() * (b.maxX - b.minX), y: b.minY + r() * (b.maxY - b.minY) };
      const got = assertFirstHit(real, v, s, `${pitch}/${yaw} at ${s.x},${s.y}`);
      if ((byLevels(real, v, s)?.id ?? null) !== (got?.id ?? null)) levelMisses++;
    }
    t.diagnostic(`pitch ${pitch} yaw ${yaw}: discrete-level form differs at ${levelMisses} of ${N} random points`);
  }
});

test("top polygon and bounds: polygon is the projected corners; fitView puts the whole map inside the viewport", (t) => {
  for (const [pitch, yaw] of CAMERAS) {
    const v = fitView(real, view(pitch, yaw), 1440, 900, 16);
    const b = screenBounds(real, v);
    assert.ok(b.minX >= 16 - 1e-6 && b.maxX <= 1440 - 16 + 1e-6 && b.minY >= 16 - 1e-6 && b.maxY <= 900 - 16 + 1e-6);
    assert.ok(Math.abs((b.minX + b.maxX) / 2 - 720) < 1e-6 && Math.abs((b.minY + b.maxY) / 2 - 450) < 1e-6);
    for (const h of real.hexes) {
      const poly = topPolygon(real, v, h);
      worldCorners(real, h).forEach((c, i) => {
        const s = project(v, c, h.z);
        assert.ok(Math.hypot(s.x - poly[i]!.x, s.y - poly[i]!.y) < 1e-9);
      });
    }
    t.diagnostic(`pitch ${pitch} yaw ${yaw}: whole map in 1440x900 (margin 16) at zoom ${v.zoom.toFixed(2)} px per side`);
  }
});

test("timing: picking every hex centre of the whole map (1492 hexes) stays under 1 ms per pick", (t) => {
  for (const [pitch, yaw] of [[38, -12], [60, 30], [0, 0]] as const) {
    const v = view(pitch, yaw);
    const screens = real.hexes.map((h) => project(v, h, h.z));
    for (const s of screens) pick(real, v, s); // warm up
    const runs = 5;
    const start = performance.now();
    for (let k = 0; k < runs; k++) for (const s of screens) pick(real, v, s);
    const perPick = (performance.now() - start) / (runs * screens.length);
    t.diagnostic(`pitch ${pitch} yaw ${yaw}: ${(perPick * 1000).toFixed(1)} µs per pick (${runs * screens.length} picks)`);
    assert.ok(perPick < 1, `${perPick} ms per pick`);
  }
});

test("both themes give a valid grid", () => {
  for (const th of themes) {
    const g = grid((id) => hexHeight(hexById.get(id)!, th.camera));
    assert.equal(g.hexes.length, 1492);
    assert.ok(g.maxZ > 0);
  }
});
