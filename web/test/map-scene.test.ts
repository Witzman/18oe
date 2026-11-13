// Renderer core without PixiJS (#44): what gets drawn where (scene.ts), the camera (camera.ts) and
// the per-hex redraw diff (tilestate.ts), against the real map. fixtures/map-geometry.json is the
// geometry of all 1492 hexes (#143); fixtures/map-zones.json adds borders and partitions:
//   ruby -Ilib -e 'require "./lib/oe/map_data"; require "json"; d = Oe::MapData.build;
//     hexes = d[:hexes].filter_map { |h| { id: h[:id], borders: h[:borders], partitions: h[:partitions] }.compact if h[:borders] || h[:partitions] };
//     File.write("web/test/fixtures/map-zones.json", JSON.generate({ _note: "...", hexes: hexes }))'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  between, centerOn, clampPan, fit, frame, panBy, zoomAt, zoomStage, ZOOM_MAX, ZOOM_MIN,
} from "../render/camera.ts";
import type { MapGeometry, MapHex } from "../render/mapdata.ts";
import { levelMatrix, mapCenter, pick, project, unproject, worldCorners, type View } from "../render/projection.ts";
import {
  BLOCK, blockKey, boxOnScreen, buildScene, engineVertexToCorner, gridEdges, mix, seaT, shade,
  terrainGlyph, terrainMark, topColor, zoneSegments,
} from "../render/scene.ts";
import { renderTheme } from "../render/theme.ts";
import { changedHexes, signatures } from "../render/tilestate.ts";
import { themeById, themes } from "../themes/index.ts";
import type { HexChange } from "../types.ts";

const here = dirname(fileURLToPath(import.meta.url));
const read = (f: string) => JSON.parse(readFileSync(join(here, "fixtures", f), "utf8"));
const base = read("map-geometry.json") as MapGeometry;
const zones = new Map((read("map-zones.json").hexes as Pick<MapHex, "id" | "borders" | "partitions">[]).map((h) => [h.id, h]));
const geometry: MapGeometry = { ...base, hexes: base.hexes.map((h) => ({ ...h, ...zones.get(h.id) })) };
const brett = renderTheme({ theme: themeById("brett"), tileStyle: "full" });
const scene = buildScene(geometry, brett);

test("levels: sea at 0, then land, hill, mountain from the theme, ascending", () => {
  const c = brett.camera;
  assert.deepEqual(scene.levels, [0, c.heightLand, c.heightLand + c.heightHill, c.heightLand + c.heightMountain]);
  for (const h of scene.grid.hexes) assert.equal(scene.levels[scene.levelOf.get(h.id)!], h.z, h.id);
});

test("plates: every hex sits on exactly the plate of its own level, in one 8 x 8 block", () => {
  const count = new Map<string, number>();
  for (const p of scene.plates) {
    for (const h of p.hexes) {
      assert.equal(scene.levelOf.get(h.id), p.level, `${h.id} on plate ${p.level}`);
      assert.equal(blockKey(h), p.block);
      count.set(h.id, (count.get(h.id) ?? 0) + 1);
    }
    const rows = p.hexes.map((h) => Math.round(h.y / 1.5)), cols = p.hexes.map((h) => Math.round(h.x / (Math.sqrt(3) / 2)));
    assert.ok(Math.max(...rows) - Math.min(...rows) < BLOCK, "at most 8 rows");
    assert.ok(Math.max(...cols) - Math.min(...cols) < 2 * BLOCK, "at most 8 hexes across");
    for (const h of p.hexes) for (const q of worldCorners(scene.grid, h)) {
      assert.ok(q.x >= p.box.minX - 1e-9 && q.x <= p.box.maxX + 1e-9 && q.y >= p.box.minY - 1e-9 && q.y <= p.box.maxY + 1e-9);
    }
  }
  for (const h of scene.grid.hexes) assert.equal(count.get(h.id), 1, h.id);
  const blocks = new Set(scene.grid.hexes.map(blockKey));
  assert.ok(blocks.size >= 25 && blocks.size <= 40, `${blocks.size} blocks`);
});

test("colours come from the theme: sea gradient north-west deep to south-east shallow, land by terrain", () => {
  for (const t of themes) {
    const rt = renderTheme({ theme: t, tileStyle: "full" });
    const m = rt.map;
    assert.equal(mix(m.seaDeep, m.seaShallow, 0), m.seaDeep);
    assert.equal(mix(m.seaDeep, m.seaShallow, 1), m.seaShallow);
    assert.equal(seaT({ x: scene.bounds.minX, y: scene.bounds.minY }, scene.bounds), 0);
    assert.equal(seaT({ x: scene.bounds.maxX, y: scene.bounds.maxY }, scene.bounds), 1);
    for (const h of geometry.hexes) {
      const g = scene.grid.byId.get(h.id)!;
      const c = topColor(h, g, m, scene.bounds);
      if (g.z === 0) assert.equal(c, mix(m.seaDeep, m.seaShallow, seaT(h, scene.bounds)));
      else {
        const kind = terrainMark(h)?.kind;
        assert.equal(c, kind === "mountain" ? m.mountain : kind === "hill" ? m.hill : kind === "water" ? m.water : m.land, h.id);
      }
    }
  }
  assert.equal(shade(0xffffff, 0.5), 0x808080);
});

test("terrain sign: mountain before hill before water, cost is the sum, sea has none", () => {
  const hex = (terrain: MapHex["terrain"], kind: MapHex["kind"] = "land") => ({ id: "X", x: 0, y: 0, kind, neighbors: [], terrain }) as MapHex;
  assert.deepEqual(terrainMark(hex([{ types: ["hill"], cost: 30 }, { types: ["river"], cost: 15 }])), { kind: "hill", cost: 45 });
  assert.deepEqual(terrainMark(hex([{ types: ["mountain"], cost: 60 }])), { kind: "mountain", cost: 60 });
  assert.deepEqual(terrainMark(hex([{ types: ["lake"], cost: 30 }])), { kind: "water", cost: 30 });
  assert.equal(terrainMark(hex([{ types: ["water"], cost: 30 }], "sea")), null);
  assert.equal(terrainMark(hex(undefined)), null);
  const marks = geometry.hexes.map(terrainMark).filter((x) => x);
  assert.ok(marks.length > 250, `${marks.length} terrain signs`);
  for (const k of ["mountain", "hill", "water"] as const) assert.ok(terrainGlyph(k).flat().every((p) => Math.hypot(p.x, p.y) < 0.3));
});

test("engine vertices: 0 is the bottom corner, then clockwise (18xx Partitions::VERTICES, pointy)", () => {
  const corners = scene.grid.shape.corners;
  const bottom = corners.reduce((best, c, i) => (c.y > corners[best]!.y ? i : best), 0);
  assert.equal(engineVertexToCorner(0), bottom);
  // Clockwise on screen (y down): from the bottom the next corner is to the lower left.
  const v1 = corners[engineVertexToCorner(1)]!;
  assert.ok(v1.x < 0 && v1.y > 0);
});

test("zone lines: each province border once, on the higher hex, none between two sea hexes", () => {
  const segs = zoneSegments(scene);
  const expected = new Set<string>();
  let partitions = 0;
  for (const h of geometry.hexes) {
    for (const b of h.borders ?? []) {
      if (b.type !== "province") continue;
      const n = h.neighbors[b.edge] ? scene.hexById.get(h.neighbors[b.edge]!) : undefined;
      if (h.kind === "sea" && (!n || n.kind === "sea")) continue;
      expected.add(n ? [h.id, n.id].sort().join("|") : `${h.id}|-${b.edge}`);
    }
    partitions += (h.partitions ?? []).filter((p) => p.type === "province").length;
  }
  assert.equal(segs.length, expected.size + partitions);
  assert.ok(expected.size > 50 && partitions > 30, `${expected.size} borders, ${partitions} partitions`);
  const r = scene.grid.shape.radius;
  for (const s of segs) {
    const owner = scene.grid.byId.get(s.hex)!;
    const len = Math.hypot(s.b.x - s.a.x, s.b.y - s.a.y);
    assert.ok(len > 0.49 * r && len < 2.01 * r, `${s.hex} length ${len}`);
    // Border endpoints are corners shared by both hexes; the owner is never the lower one.
    const touch = scene.grid.hexes.filter((h) => worldCorners(scene.grid, h).some((c) => Math.hypot(c.x - s.a.x, c.y - s.a.y) < 1e-6));
    assert.ok(touch.some((h) => h.id === owner.id) || Math.hypot(s.a.x - owner.x, s.a.y - owner.y) < r + 1e-6, `${s.hex} owner`);
  }
  // A half-length partition (R39: a:2, b:5, length 0.5) ends at the hex centre.
  const r39 = scene.grid.byId.get("R39")!;
  const half = segs.filter((s) => s.hex === "R39");
  assert.equal(half.length, 2);
  for (const s of half) assert.ok(Math.hypot(s.b.x - r39.x, s.b.y - r39.y) < 1e-6, `R39 ends at ${JSON.stringify(s)} centre ${r39.x},${r39.y}`);
});

test("hex lines: every edge between two hexes on the same level once, every other edge per hex", () => {
  let drawn = 0, expected = 0;
  for (const h of scene.grid.hexes) {
    drawn += gridEdges(scene, h).length;
    for (let i = 0; i < 6; i++) {
      const n = h.neighbors[i] ? scene.grid.byId.get(h.neighbors[i]!) : undefined;
      expected += n && n.z === h.z ? 0.5 : 1;
    }
  }
  assert.equal(drawn, expected);
});

// ---------------------------------------------------------------------------
// Camera

const center = mapCenter(scene.grid);
const vp = { width: 1440, height: 900 };
const start = (pitch: number, yaw: number): View => fit(scene.grid, { pitch, yaw, zoom: 1, panX: 0, panY: 0, centerX: center.x, centerY: center.y }, vp);
const CAMS: [number, number][] = [[0, 0], [38, -12], [60, 30]];
const close = (a: number, b: number, eps = 1e-6) => Math.abs(a - b) < eps;

test("zoom about the pointer keeps what is under it in place, at every height, within 0.35x to 4x", () => {
  for (const [pitch, yaw] of CAMS) {
    const v0 = start(pitch, yaw);
    const s = { x: 400, y: 300 };
    const v1 = zoomAt(v0, s, 1.7, v0.zoom);
    for (const z of scene.levels) {
      const w = unproject(v0, s, z);
      const back = project(v1, w, z);
      assert.ok(close(back.x, s.x) && close(back.y, s.y), `z ${z}`);
    }
    // The hex under the pointer stays the hex under the pointer.
    assert.equal(pick(scene.grid, v1, s)?.id, pick(scene.grid, v0, s)?.id);
    assert.ok(close(zoomAt(v0, s, 100, v0.zoom).zoom, v0.zoom * ZOOM_MAX));
    assert.ok(close(zoomAt(v0, s, 0.01, v0.zoom).zoom, v0.zoom * ZOOM_MIN));
  }
});

test("pan and clamp: the map cannot be dragged out of the window", () => {
  for (const [pitch, yaw] of CAMS) {
    const v0 = start(pitch, yaw);
    assert.deepEqual(clampPan(v0, scene.bounds, vp), v0, "fitted view is left alone");
    const moved = panBy(v0, 30, -20);
    assert.deepEqual([moved.panX - v0.panX, moved.panY - v0.panY], [30, -20]);
    for (const [dx, dy] of [[1e5, 0], [-1e5, 0], [0, 1e5], [0, -1e5]] as const) {
      const v = clampPan(panBy(zoomAt(v0, { x: 720, y: 450 }, 4, v0.zoom), dx, dy), scene.bounds, vp);
      // The middle of the window is still over the map.
      const mid = unproject(v, { x: 720, y: 450 }, 0);
      const b = scene.bounds;
      assert.ok(mid.x >= b.minX - 1e-6 && mid.x <= b.maxX + 1e-6 && mid.y >= b.minY - 1e-6 && mid.y <= b.maxY + 1e-6, `pan ${dx},${dy}`);
      assert.ok(scene.grid.hexes.some((h) => {
        const p = project(v, h, 0);
        return p.x >= 0 && p.x <= vp.width && p.y >= 0 && p.y <= vp.height;
      }), `pan ${dx},${dy}: no hex in the window`);
    }
  }
});

test("centre, frame and fly: points end up in the middle and in view; the flight starts and ends right", () => {
  for (const [pitch, yaw] of CAMS) {
    const v0 = start(pitch, yaw);
    const paris = scene.grid.byId.get("Q30")!;
    const c = centerOn(v0, paris, paris.z, vp, 30);
    const p = project(c, paris, paris.z);
    assert.ok(close(p.x, 720) && close(p.y, 450) && c.zoom === 30);
    assert.equal(pick(scene.grid, c, { x: 720, y: 450 })?.id, "Q30");
    const pts = ["Q30", "R55", "M28"].map((id) => scene.grid.byId.get(id)!);
    const f = frame(v0, pts, brett.camera.heightLand, vp, 40);
    for (const q of pts) {
      const s = project(f, q, brett.camera.heightLand);
      assert.ok(s.x > 0 && s.x < vp.width && s.y > 0 && s.y < vp.height, q.id);
    }
    assert.ok(frame(v0, [paris], paris.z, vp, 40).zoom <= 40, "one hex is not zoomed in further than the cap");
    const a = between(v0, c, 0, vp), b = between(v0, c, 1, vp);
    for (const k of ["zoom", "panX", "panY"] as const) {
      assert.ok(close(a[k], v0[k]), `start ${k}`);
      assert.ok(close(b[k], c[k]), `end ${k}`);
    }
    // The world point at the window centre moves on a straight line.
    const mid = (t: number) => unproject(between(v0, c, t, vp), { x: 720, y: 450 }, 0);
    const [m0, m5, m1] = [mid(0), mid(0.5), mid(1)];
    const cross = (m5.x - m0.x) * (m1.y - m0.y) - (m5.y - m0.y) * (m1.x - m0.x);
    assert.ok(Math.abs(cross) < 1e-6);
  }
});

test("zoom stages by hex side on screen: Z0 under 14 px, Z1 to 34 px, Z2 above", () => {
  assert.deepEqual([13.9, 14, 34, 34.1].map(zoomStage), [0, 1, 1, 2]);
  const v = start(38, -12);
  assert.equal(zoomStage(v.zoom), 1, `fitted 1440 x 900 is ${v.zoom.toFixed(1)} px per side`);
});

test("culling: a block box is on screen exactly when its projection overlaps the window", () => {
  const v = centerOn(start(38, -12), scene.grid.byId.get("Q30")!, brett.camera.heightLand, vp, 60);
  let on = 0;
  for (const p of scene.plates) {
    const z = scene.levels[p.level]!;
    const visible = boxOnScreen(p.box, v, z, vp.width, vp.height);
    // Any hex corner on screen means the box is on screen.
    const m = levelMatrix(v, z);
    const anyCorner = p.hexes.some((h) => worldCorners(scene.grid, h).some((c) => {
      const s = { x: m.a * c.x + m.c * c.y + m.tx, y: m.b * c.x + m.d * c.y + m.ty };
      return s.x >= 0 && s.x <= vp.width && s.y >= 0 && s.y <= vp.height;
    }));
    if (anyCorner) assert.ok(visible, p.block);
    if (visible) on++;
  }
  assert.ok(on > 0 && on < scene.plates.length / 2, `${on} of ${scene.plates.length} plates on screen at 60 px per side`);
});

// ---------------------------------------------------------------------------
// Per-hex redraw

test("tile diff: only hexes whose tile, rotation, colour, tokens or builder changed", () => {
  const e = (hex: string, name: string, rotation = 0, extra: Partial<HexChange> = {}): HexChange =>
    ({ hex, tile: { name, rotation, color: "yellow" }, ...extra });
  const a = signatures([e("Q30", "57"), e("R55", "8"), e("M28", "9")]);
  assert.deepEqual(changedHexes(a, a), []);
  const b = signatures([
    e("Q30", "57"), e("R55", "8", 2), e("M28", "9", 0, { tokens: [{ city: 0, corporations: ["LNWR"] }] }), e("S42", "58"),
  ]);
  assert.deepEqual(changedHexes(a, b), ["M28", "R55", "S42"]);
  assert.deepEqual(changedHexes(b, signatures([e("Q30", "57")])), ["M28", "R55", "S42"], "removed entries count");
  const built = signatures([{ hex: "Q30", tile: { name: "57", rotation: 0, color: "yellow", laid_by: "PLM" } as HexChange["tile"] }]);
  assert.deepEqual(changedHexes(a, built).includes("Q30"), true, "builder (laid_by, #150) counts");
});
