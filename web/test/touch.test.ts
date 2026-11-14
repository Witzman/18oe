// Touch helpers (#259): hexes within a finger's reach, finger-sized hexes, slot lists, release velocity and inertia.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import type { MapGeometry } from "../render/mapdata.ts";
import { buildGrid, mapCenter, project, type View } from "../render/projection.ts";
import { slotsNear, type Slot } from "../render/stones.ts";
import { hexesNear, hexIsFingerSized, inertiaStep, INERTIA_STOP, pushSample, releaseVelocity } from "../render/touch.ts";
import { themeById, themes } from "../themes/index.ts";
import { renderTheme } from "../render/theme.ts";

const here = dirname(fileURLToPath(import.meta.url));
const map = JSON.parse(readFileSync(join(here, "fixtures", "map-geometry.json"), "utf8")) as MapGeometry;
const grid = buildGrid(map.hexes, map.layout.edge_vectors, () => 0);
const c = mapCenter(grid);
const view = (zoom: number): View => ({ pitch: 0, yaw: 0, zoom, panX: 600, panY: 400, centerX: c.x, centerY: c.y });

test("hexesNear: nearest first, only within reach, limited; at large zoom a finger touches one hex", () => {
  const v = view(4);
  const h = grid.hexes[700]!;
  const p = project(v, { x: h.x, y: h.y }, h.z);
  const near = hexesNear(grid, v, p, 22);
  assert.equal(near[0], h.id);
  assert.ok(near.length > 1 && near.length <= 5, `${near.length} candidates at zoom 4`);
  for (const id of near) {
    const g = grid.byId.get(id)!;
    const q = project(v, { x: g.x, y: g.y }, g.z);
    assert.ok(Math.hypot(q.x - p.x, q.y - p.y) <= 22);
  }
  const big = view(60);
  const p2 = project(big, { x: h.x, y: h.y }, h.z);
  assert.deepEqual(hexesNear(grid, big, p2, 22), [h.id]);
  assert.equal(hexesNear(grid, v, { x: -1000, y: -1000 }, 22).length, 0);
});

test("hexIsFingerSized: a hex is wide enough for a 44 px target from about 25 px side length", () => {
  assert.equal(hexIsFingerSized(10, 22), false);
  assert.equal(hexIsFingerSized(25.5, 22), true);
  assert.equal(hexIsFingerSized(60, 22), true);
});

test("slotsNear: nearest first, within reach only", () => {
  const slots: Slot[] = [0, 1, 2, 3].map((i) => ({ city: 0, slot: i, pos: { x: i * 0.2, y: 0 } }));
  assert.deepEqual(slotsNear(slots, { x: 0.09, y: 0 }, 0.15).map((s) => s.slot), [0, 1]);
  assert.deepEqual(slotsNear(slots, { x: 0.3, y: 0 }, 0.05).map((s) => s.slot), []);
  assert.deepEqual(slotsNear(slots, { x: 0.45, y: 0 }, 0.3).map((s) => s.slot), [2, 3, 1]);
});

test("release velocity: px per ms over the last 100 ms, zero after a rest or with one sample", () => {
  let s = pushSample([], { t: 0, p: { x: 0, y: 0 } });
  s = pushSample(s, { t: 50, p: { x: 50, y: 25 } });
  s = pushSample(s, { t: 100, p: { x: 100, y: 50 } });
  assert.deepEqual(releaseVelocity(s, 110), { x: 1, y: 0.5 });
  assert.deepEqual(releaseVelocity(s, 400), { x: 0, y: 0 }, "finger rested");
  assert.deepEqual(releaseVelocity(pushSample([], { t: 0, p: { x: 1, y: 1 } }), 5), { x: 0, y: 0 });
  s = pushSample(s, { t: 300, p: { x: 400, y: 50 } });
  assert.equal(s.length, 1, "old samples dropped");
});

test("inertia decays: total glide is v * tau, independent of the step size, and stops below the threshold", () => {
  for (const dt of [4, 16, 33]) {
    let v = { x: 2, y: 0 }, x = 0, t = 0;
    while (Math.hypot(v.x, v.y) > 1e-6 && t < 20000) { const [d, n] = inertiaStep(v, dt, 350); x += d.x; v = n; t += dt; }
    assert.ok(Math.abs(x - 2 * 350) < 1, `dt ${dt}: ${x}`);
  }
  let v = { x: 1, y: 0 }, t = 0;
  while (Math.hypot(v.x, v.y) > INERTIA_STOP) { v = inertiaStep(v, 16, 350)[1]; t += 16; }
  assert.ok(t > 500 && t < 2500, `stops after ${t} ms`);
});

test("theme tokens: both themes carry finger-sized hit values (44 px target) and gesture timing", () => {
  assert.ok(themes.length >= 2);
  for (const th of themes) {
    const r = renderTheme({ theme: themeById(th.id), tileStyle: "full" });
    assert.ok(r.hitTouchPx * 2 >= 44, `${th.id}: touch hit diameter ${r.hitTouchPx * 2}`);
    assert.ok(r.hitTouchPx > r.hitPx && r.dragTouchPx > r.dragPx);
    assert.ok(themeById(th.id).motion.inertiaMs > 0 && themeById(th.id).motion.doubleTapMs > 0);
  }
});
