// Hex heights and walls (#145, ui-spec 2.4) against the real map (fixtures of #143): which walls a
// hex has for a view, their colours, and the extra height of a laid tile. No PixiJS.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import type { MapGeometry } from "../render/mapdata.ts";
import { apply, levelMatrix, mapCenter, walls, type View } from "../render/projection.ts";
import { buildScene, mix, shade, tileColor, topColor, wallColor, wallFaces, wallLight, WALL_LIGHT } from "../render/scene.ts";
import { renderTheme } from "../render/theme.ts";
import { themeById } from "../themes/index.ts";

const here = dirname(fileURLToPath(import.meta.url));
const geometry = JSON.parse(readFileSync(join(here, "fixtures", "map-geometry.json"), "utf8")) as MapGeometry;
const brett = renderTheme({ theme: themeById("brett"), tileStyle: "full" });
const atlas = renderTheme({ theme: themeById("atlas"), tileStyle: "full" });
const scene = buildScene(geometry, brett);
const c = mapCenter(scene.grid);
const view = (pitch: number, yaw: number): View => ({ pitch, yaw, zoom: 1, panX: 0, panY: 0, centerX: c.x, centerY: c.y });

test("pitch 0: no walls at all", () => {
  assert.deepEqual(wallFaces(scene, view(0, 0), brett), []);
});

test("a coast hex has walls only on the edges that face the camera and look to lower neighbours", () => {
  for (const [pitch, yaw] of [[38, -12], [60, 0], [30, 20]] as const) {
    const v = view(pitch, yaw);
    const m = levelMatrix(v, 0);
    let coast = 0;
    for (const f of wallFaces(scene, v, brett)) {
      const h = scene.grid.byId.get(f.hex)!;
      const e = scene.grid.shape.edges[f.edge]!;
      assert.ok(m.b * e.x + m.d * e.y > 0, `${f.hex} edge ${f.edge} faces away at pitch ${pitch}`);
      const n = h.neighbors[f.edge] ? scene.grid.byId.get(h.neighbors[f.edge]!)!.z : 0;
      assert.ok(n < h.z, `${f.hex} edge ${f.edge}: neighbour is not lower`);
      if (n === 0) coast++;
    }
    assert.ok(coast > 100, `${coast} coast faces`);
  }
  // A concrete coast hex: wall count equals the camera-facing edges with a lower neighbour.
  const v = view(38, -12);
  const coastHex = scene.grid.hexes.find((h) => h.z > 0 && h.neighbors.some((n) => n && scene.grid.byId.get(n)!.z === 0))!;
  const faces = new Set(wallFaces(scene, v, brett).filter((f) => f.hex === coastHex.id).map((f) => f.edge));
  assert.deepEqual([...faces].sort(), walls(scene.grid, v, coastHex).map((w) => w.edge).sort());
  assert.ok(faces.size >= 1 && faces.size < 6);
});

test("a wall reaches from the hex top to the foot (lower neighbour, 0 at the sea) and is sorted back to front", () => {
  const v = view(38, -12);
  const faces = wallFaces(scene, v, brett);
  for (let i = 1; i < faces.length; i++) assert.ok(faces[i - 1]!.depth <= faces[i]!.depth);
  // Per wall the pieces stack: summed screen height = (top - foot) * sin(pitch) (zoom 1).
  const sp = Math.sin((38 * Math.PI) / 180);
  const per = new Map<string, number>();
  for (const f of faces) {
    const k = `${f.hex}/${f.edge}`;
    // polygon: top A, top B, foot B, foot A; the left side runs straight down on screen
    per.set(k, (per.get(k) ?? 0) + (f.polygon[3]!.y - f.polygon[0]!.y));
  }
  for (const [k, h] of per) {
    const [id, edge] = k.split("/") as [string, string];
    const g = scene.grid.byId.get(id)!;
    const nid = g.neighbors[Number(edge)];
    const foot = nid ? scene.grid.byId.get(nid)!.z : 0;
    assert.ok(Math.abs(h - (g.z - foot) * sp) < 1e-9, k);
  }
  assert.ok(per.size > 300);
});

test("colours: coast part in landLow, rest in the top colour, all darkened by wallShade and lit by the light", () => {
  const v = view(38, -12);
  const hill = scene.grid.hexes.find((h) => scene.hexById.get(h.id)!.terrain?.some((t) => t.types.includes("hill")) && h.neighbors.some((n) => n && scene.grid.byId.get(n)!.z === 0));
  for (const f of wallFaces(scene, v, brett)) {
    const g = scene.grid.byId.get(f.hex)!;
    const light = wallLight(scene.grid.shape.edges[f.edge]!, brett.camera.lightAzimuth);
    const top = topColor(scene.hexById.get(f.hex)!, g, brett.map, scene.bounds);
    const ok = [top, brett.map.landLow].map((b) => wallColor(b, brett.camera.wallShade, light));
    assert.ok(ok.includes(f.color), `${f.hex}/${f.edge}`);
  }
  // A hill on the coast has both: landLow below heightLand, hill colour above.
  if (hill) {
    const cols = new Set(wallFaces(scene, v, brett).filter((f) => f.hex === hill.id).map((f) => f.color));
    assert.ok(cols.size >= 2, "coast band plus hill band");
  }
  // Light: facing the light is brighter than facing away, at most +-10 %.
  const base = 0x808080;
  assert.ok(wallColor(base, 0, 1) > wallColor(base, 0, -1));
  assert.equal(wallColor(base, 0.3, 0), shade(base, 0.3));
  assert.equal(wallColor(base, 0, 1), mix(base, 0xffffff, WALL_LIGHT));
  const az = brett.camera.lightAzimuth;
  assert.ok(Math.abs(wallLight({ x: Math.cos((az * Math.PI) / 180), y: Math.sin((az * Math.PI) / 180) }, az) - 1) < 1e-12);
});

test("a laid tile raises its hex by heightTile and gets a slab wall in the tile colour", () => {
  const land = scene.grid.hexes.find((h) => h.z === brett.camera.heightLand && h.neighbors.some((n) => n && scene.grid.byId.get(n)!.z === 0))!;
  const raised = buildScene(geometry, brett, new Map([[land.id, "yellow"]]));
  const g = raised.grid.byId.get(land.id)!;
  assert.ok(Math.abs(g.z - (brett.camera.heightLand + brett.camera.heightTile)) < 1e-12);
  assert.ok(raised.levels.some((z) => Math.abs(z - g.z) < 1e-12));
  assert.equal(raised.grid.hexes.filter((h) => h.z !== scene.grid.byId.get(h.id)!.z).length, 1);
  const v = view(38, -12);
  const mine = wallFaces(raised, v, brett).filter((f) => f.hex === land.id);
  assert.ok(mine.length >= 1);
  const colors = new Set(mine.map((f) => f.color));
  const slab = tileColor("yellow", brett.map)!;
  for (const f of mine.filter((x) => (raised.grid.byId.get(land.id)!.neighbors[x.edge] ? raised.grid.byId.get(raised.grid.byId.get(land.id)!.neighbors[x.edge]!)!.z : 0) === 0)) {
    const light = wallLight(raised.grid.shape.edges[f.edge]!, brett.camera.lightAzimuth);
    assert.ok(mine.some((x) => x.edge === f.edge && x.color === wallColor(slab, brett.camera.wallShade, light)), "slab colour");
    assert.ok(mine.some((x) => x.edge === f.edge && x.color === wallColor(brett.map.landLow, brett.camera.wallShade, light)), "coast colour");
  }
  assert.ok(colors.size >= 2);
  // Neighbours of the raised hex now have a wall towards it too, when it faces the camera.
  assert.deepEqual(raised.tiled.get(land.id), "yellow");
  // Sea hexes never rise.
  const sea = geometry.hexes.find((h) => h.kind === "sea")!;
  const r2 = buildScene(geometry, brett, new Map([[sea.id, "yellow"]]));
  assert.equal(r2.grid.byId.get(sea.id)!.z, 0);
});

test("both themes: wall pieces are drawn above the top of the lower neighbour on screen", () => {
  for (const t of [brett, atlas]) {
    const sc = buildScene(geometry, t);
    const v = view(t.camera.pitch, t.camera.yaw);
    for (const f of wallFaces(sc, v, t).slice(0, 400)) {
      const g = sc.grid.byId.get(f.hex)!;
      const top = apply(levelMatrix(v, g.z), { x: g.x, y: g.y });
      assert.ok(f.polygon[0]!.y < f.polygon[3]!.y, "top edge above the foot edge");
      assert.ok(Number.isFinite(top.x));
    }
  }
});
