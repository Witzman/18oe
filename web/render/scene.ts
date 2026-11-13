// What the map renderer draws, as plain data (#44, ui-spec 2.3/2.4/2.7). No PixiJS here: the
// layer modules turn this into Graphics, the tests check it under `node --test`.
//
// The map is a model on a table: the sea is the lowest plate (z = 0), land is a raised plate,
// hills and mountains are raised further, a laid tile adds heightTile (#145). A plate is the
// top of the hexes of one height level in one block. The walls (#145, wallFaces) are the front
// faces between a hex and its lower neighbours, drawn per level so a higher hex covers them.
import { hexHeight, type MapGeometry, type MapHex } from "./mapdata.ts";
import { apply, buildGrid, levelMatrix, walls, worldCorners, type Box, type GridHex, type HexGrid, type Vec, type View } from "./projection.ts";
import type { RenderTheme } from "./theme.ts";

/** Hexes per block side (ui-spec 2.3): static layers are drawn, culled and cached per block. */
export const BLOCK = 8;

const ROW_STEP = 1.5;
const COL_STEP = Math.sqrt(3) / 2;

/** Block of a hex: 8 rows by 8 hexes (16 column numbers, a row uses every other column). */
export function blockKey(hex: { x: number; y: number }): string {
  const row = Math.round(hex.y / ROW_STEP), col = Math.round(hex.x / COL_STEP);
  return `${Math.floor(row / BLOCK)}:${Math.floor(col / (2 * BLOCK))}`;
}

export interface Plate {
  /** Index into Scene.levels. */
  level: number;
  block: string;
  /** Hexes whose top is on this level. */
  hexes: GridHex[];
  /** World box around the hexes' corners. */
  box: Box;
}

export interface Scene {
  geometry: MapGeometry;
  grid: HexGrid;
  hexById: Map<string, MapHex>;
  /** Distinct heights, ascending (index 0 is the sea, z = 0). */
  levels: number[];
  levelOf: Map<string, number>;
  plates: Plate[];
  /** World box around every hex. */
  bounds: Box;
  /** Hexes raised by a laid tile (#145), with the colour name of that tile. */
  tiled: ReadonlyMap<string, string>;
}

function emptyBox(): Box {
  return { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
}

function grow(box: Box, p: Vec): void {
  if (p.x < box.minX) box.minX = p.x;
  if (p.x > box.maxX) box.maxX = p.x;
  if (p.y < box.minY) box.minY = p.y;
  if (p.y > box.maxY) box.maxY = p.y;
}

/** Heights from the theme camera (ui-spec 2.4); `tiled` = hexes with a laid tile, which stand heightTile higher. */
export function buildScene(geometry: MapGeometry, theme: Pick<RenderTheme, "camera">, tiled: ReadonlyMap<string, string> = new Map()): Scene {
  const hexById = new Map(geometry.hexes.map((h) => [h.id, h]));
  const grid = buildGrid(geometry.hexes, geometry.layout.edge_vectors, (id) => hexHeight(hexById.get(id)!, theme.camera, tiled.has(id)));
  const levels = [...grid.levels].sort((a, b) => a - b);
  if (levels[0] !== 0) levels.unshift(0);
  const levelOf = new Map(grid.hexes.map((h) => [h.id, levels.indexOf(h.z)]));
  const bounds = emptyBox();
  const byKey = new Map<string, Plate>();
  for (const h of grid.hexes) {
    const corners = worldCorners(grid, h);
    corners.forEach((p) => grow(bounds, p));
    const key = blockKey(h);
    const l = levelOf.get(h.id)!;
    const k = `${l}/${key}`;
    let plate = byKey.get(k);
    if (!plate) byKey.set(k, (plate = { level: l, block: key, hexes: [], box: emptyBox() }));
    plate.hexes.push(h);
    corners.forEach((p) => grow(plate!.box, p));
  }
  const plates = [...byKey.values()].sort((a, b) => a.level - b.level || a.block.localeCompare(b.block));
  return { geometry, grid, hexById, levels, levelOf, plates, bounds, tiled };
}

// ---------------------------------------------------------------------------
// Colours (all from the theme; nothing is written down here)

type MapColors = RenderTheme["map"];

export function mix(a: number, b: number, t: number): number {
  const ch = (n: number, s: number) => (n >> s) & 255;
  const m = (s: number) => Math.round(ch(a, s) + (ch(b, s) - ch(a, s)) * t);
  return (m(16) << 16) | (m(8) << 8) | m(0);
}

/** Darken a colour by k (0 = unchanged, 1 = black). */
export function shade(c: number, k: number): number {
  return mix(c, 0x000000, k);
}

/** Position of a sea hex in the gradient: 0 north-west (seaDeep) to 1 south-east (seaShallow). */
export function seaT(p: Vec, bounds: Box): number {
  const u = (p.x - bounds.minX) / Math.max(1e-9, bounds.maxX - bounds.minX);
  const v = (p.y - bounds.minY) / Math.max(1e-9, bounds.maxY - bounds.minY);
  return Math.min(1, Math.max(0, (u + v) / 2));
}

export type TerrainKind = "mountain" | "hill" | "water";

/** Terrain sign of a land hex (ui-spec 2.7): the strongest type wins, the cost is the sum of all upgrades. */
export function terrainMark(hex: MapHex): { kind: TerrainKind; cost: number } | null {
  if (hex.kind === "sea" || !hex.terrain?.length) return null;
  const types = new Set(hex.terrain.flatMap((t) => t.types));
  const kind: TerrainKind | null = types.has("mountain") ? "mountain" : types.has("hill") ? "hill"
    : types.has("water") || types.has("river") || types.has("lake") ? "water" : null;
  if (!kind) return null;
  return { kind, cost: hex.terrain.reduce((s, t) => s + t.cost, 0) };
}

/** Colour of a hex top: sea gradient, or land tinted by terrain. Off-boards are coloured by their tile (tiles layer). */
export function topColor(hex: MapHex, gridHex: GridHex, map: MapColors, bounds: Box): number {
  if (gridHex.z === 0) return mix(map.seaDeep, map.seaShallow, seaT(hex, bounds));
  const mark = terrainMark(hex);
  if (mark?.kind === "mountain") return map.mountain;
  if (mark?.kind === "hill") return map.hill;
  if (mark?.kind === "water") return map.water;
  return map.land;
}

const TILE_COLOR = { yellow: "tileYellow", green: "tileGreen", brown: "tileBrown", gray: "tileGray", red: "tileRed" } as const;

/** Surface colour of a tile colour name (map.tile<Colour>), null for tiles without a coloured surface. */
export function tileColor(color: string | undefined, map: MapColors): number | null {
  const key = TILE_COLOR[color as keyof typeof TILE_COLOR];
  return key ? map[key] : null;
}

// ---------------------------------------------------------------------------
// Walls (#145, ui-spec 2.4)

/** Brightness change of a wall by its angle to the light, at most +-this (ui-spec 2.4). */
export const WALL_LIGHT = 0.1;

/**
 * Light on a wall: cos of the angle between its outward normal and the direction towards the
 * light (camera.lightAzimuth, degrees, same convention as the token shadow: the light lies at
 * (cos az, sin az) in world x/y). Facing the light = 1, away = -1.
 */
export function wallLight(normal: Vec, azimuth: number): number {
  const az = (azimuth * Math.PI) / 180;
  const len = Math.hypot(normal.x, normal.y) || 1;
  return (normal.x * Math.cos(az) + normal.y * Math.sin(az)) / len;
}

/** Colour of a wall face: base darkened by wallShade, then lightened or darkened by up to WALL_LIGHT by the light. */
export function wallColor(base: number, wallShade: number, light: number): number {
  const c = shade(base, wallShade);
  return light >= 0 ? mix(c, 0xffffff, WALL_LIGHT * light) : mix(c, 0x000000, -WALL_LIGHT * light);
}

export interface WallFace {
  hex: string;
  edge: number;
  /** Index into Scene.levels of the hex (the level container the face is drawn in). */
  level: number;
  /** Screen polygon of the view given to wallFaces (top corner A, B, foot B, A). */
  polygon: Vec[];
  color: number;
  /** Back to front, ascending. */
  depth: number;
}

/**
 * The visible wall faces of the whole map for a view (none at pitch 0). A wall runs from the hex
 * top down to the lower neighbour's top (0 at the map border) and is split where its colour
 * changes: the tile slab in the tile's colour, the part below heightLand next to the sea in
 * map.landLow (the coast), the rest in the hex top colour; all darkened by wallShade and lit by
 * the light direction. Pass a view with zoom 1 and pan 0 to get unit coordinates.
 */
export function wallFaces(scene: Scene, view: View, theme: Pick<RenderTheme, "camera" | "map">): WallFace[] {
  const out: WallFace[] = [];
  const { camera, map } = theme;
  const eps = 1e-9;
  const edges = scene.grid.shape.edges;
  for (const h of scene.grid.hexes) {
    const hex = scene.hexById.get(h.id)!;
    const tileName = scene.tiled.get(h.id);
    const ground = tileName === undefined ? h.z : h.z - camera.heightTile;
    const slab = tileName === undefined ? null : tileColor(tileName, map);
    const corners = worldCorners(scene.grid, h);
    for (const w of walls(scene.grid, view, h)) {
      const breaks = [...new Set([w.bottom, h.z, ...scene.levels, camera.heightLand, ground])]
        .filter((z) => z >= w.bottom - eps && z <= h.z + eps).sort((a, b) => a - b);
      const a = corners[(w.edge + 5) % 6]!, b = corners[w.edge]!;
      const e = edges[w.edge]!;
      const light = wallLight(e, camera.lightAzimuth);
      for (let i = 0; i + 1 < breaks.length; i++) {
        const lo = breaks[i]!, hi = breaks[i + 1]!;
        if (hi - lo < eps) continue;
        const base = slab !== null && lo >= ground - eps ? slab
          : w.bottom === 0 && hi <= camera.heightLand + eps ? map.landLow
          : topColor(hex, h, map, scene.bounds);
        const mlo = levelMatrix(view, lo), mhi = levelMatrix(view, hi);
        out.push({
          hex: h.id, edge: w.edge, level: scene.levelOf.get(h.id)!,
          polygon: [apply(mhi, a), apply(mhi, b), apply(mlo, b), apply(mlo, a)],
          color: wallColor(base, camera.wallShade, light), depth: w.depth,
        });
      }
    }
  }
  return out.sort((p, q) => p.depth - q.depth);
}

// ---------------------------------------------------------------------------
// Lines: province borders and partitions (ui-spec 2.7, map.zoneBorder)

export interface Segment {
  /** Hex whose level the line is drawn on. */
  hex: string;
  a: Vec;
  b: Vec;
}

/** Engine vertex numbering (Part::Partition: 0 = bottom vertex, clockwise) to our corner index. */
export function engineVertexToCorner(v: number): number {
  return (v + 5) % 6;
}

/**
 * Province borders, each shared edge once, drawn on the higher of the two hexes (so the higher
 * plate does not cover it). Not drawn here: province borders between two sea hexes (they separate
 * sea zones: map.seaZoneLine, #153) and other border types (impassable).
 * Partitions run straight from vertex a towards vertex b, `length` of the way (as 18xx draws them;
 * the engine's a_sign/b_sign are not in /map, and 18OE uses none).
 */
export function zoneSegments(scene: Scene): Segment[] {
  const out: Segment[] = [];
  const seen = new Set<string>();
  const { grid } = scene;
  for (const hex of scene.geometry.hexes) {
    const g = grid.byId.get(hex.id)!;
    for (const b of hex.borders ?? []) {
      if (b.type !== "province") continue;
      const nid = hex.neighbors[b.edge] ?? null;
      const other = nid ? scene.hexById.get(nid) : undefined;
      if (hex.kind === "sea" && (!other || other.kind === "sea")) continue;
      const pair = nid ? [hex.id, nid].sort().join("|") : `${hex.id}|-${b.edge}`;
      if (seen.has(pair)) continue;
      seen.add(pair);
      const n = nid ? grid.byId.get(nid) : undefined;
      const owner = n && n.z > g.z ? n : g;
      const corners = worldCorners(grid, g);
      out.push({ hex: owner.id, a: corners[(b.edge + 5) % 6]!, b: corners[b.edge]! });
    }
    for (const p of hex.partitions ?? []) {
      if (p.type !== "province") continue;
      const corners = worldCorners(grid, g);
      const a = corners[engineVertexToCorner(p.a)]!, b = corners[engineVertexToCorner(p.b)]!;
      const k = p.length ?? 1;
      out.push({ hex: hex.id, a, b: { x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k } });
    }
  }
  return out;
}

/** Each hex outline edge once per level: an edge shared by two hexes on the same level is drawn by one of them. */
export function gridEdges(scene: Scene, h: GridHex): number[] {
  const out: number[] = [];
  for (let i = 0; i < 6; i++) {
    const nid = h.neighbors[i];
    const n = nid ? scene.grid.byId.get(nid) : undefined;
    if (n && n.z === h.z && n.id < h.id) continue;
    out.push(i);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Terrain glyphs (world units, relative to the hex centre)

/** Polylines of a terrain sign, side length 1; drawn in map.label next to the cost number. */
export function terrainGlyph(kind: TerrainKind): Vec[][] {
  const s = 0.16;
  if (kind === "mountain") return [[{ x: -s, y: s * 0.6 }, { x: -s * 0.3, y: -s * 0.6 }, { x: 0, y: 0 }, { x: s * 0.4, y: -s * 0.8 }, { x: s, y: s * 0.6 }]];
  if (kind === "hill") {
    const arc: Vec[] = [];
    for (let i = 0; i <= 8; i++) {
      const a = Math.PI * (1 + i / 8);
      arc.push({ x: Math.cos(a) * s, y: Math.sin(a) * s * 0.8 + s * 0.4 });
    }
    return [arc];
  }
  const wave = (dy: number) => Array.from({ length: 9 }, (_, i) => ({ x: -s + (2 * s * i) / 8, y: dy + Math.sin((i / 8) * 2 * Math.PI) * s * 0.25 }));
  return [wave(-s * 0.3), wave(s * 0.35)];
}

/** Where the sign and its cost sit on the hex (left and right of a point above the centre). */
export const GLYPH_AT: Vec = { x: -0.22, y: -0.42 };
export const COST_AT: Vec = { x: 0.16, y: -0.42 };

// ---------------------------------------------------------------------------
// Culling

/** Is the world box (on height z) on screen, within a margin in px? */
export function boxOnScreen(box: Box, view: View, z: number, width: number, height: number, margin = 0): boolean {
  const m = levelMatrix(view, z);
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of [{ x: box.minX, y: box.minY }, { x: box.maxX, y: box.minY }, { x: box.minX, y: box.maxY }, { x: box.maxX, y: box.maxY }]) {
    const s = apply(m, p);
    if (s.x < minX) minX = s.x;
    if (s.x > maxX) maxX = s.x;
    if (s.y < minY) minY = s.y;
    if (s.y > maxY) maxY = s.y;
  }
  return maxX >= -margin && minX <= width + margin && maxY >= -margin && minY <= height + margin;
}
