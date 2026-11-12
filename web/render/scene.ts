// What the map renderer draws, as plain data (#44, ui-spec 2.3/2.4/2.7). No PixiJS here: the
// layer modules turn this into Graphics, the tests check it under `node --test`.
//
// The map is a model on a table: the sea is the lowest plate (z = 0), land is a raised plate,
// hills and mountains are raised further. Every height level is drawn as a plate under all hexes
// that reach at least that high, so between two levels the lower plate shows as a darker rim
// (in the colour of the hex above, shaded by camera.wallShade). That stands in for the walls
// until #145 draws real ones; the walls layer stays empty here.
import { hexHeight, type MapGeometry, type MapHex } from "./mapdata.ts";
import { apply, buildGrid, levelMatrix, worldCorners, type Box, type GridHex, type HexGrid, type Vec, type View } from "./projection.ts";
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
  /** Hexes whose column reaches this level (top >= level). */
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

/** Heights from the theme camera (ui-spec 2.4). Laid tiles do not raise a hex yet (heightTile is #145). */
export function buildScene(geometry: MapGeometry, theme: Pick<RenderTheme, "camera">): Scene {
  const hexById = new Map(geometry.hexes.map((h) => [h.id, h]));
  const grid = buildGrid(geometry.hexes, geometry.layout.edge_vectors, (id) => hexHeight(hexById.get(id)!, theme.camera));
  const levels = [...grid.levels].sort((a, b) => a - b);
  if (levels[0] !== 0) levels.unshift(0);
  const levelOf = new Map(grid.hexes.map((h) => [h.id, levels.indexOf(h.z)]));
  const bounds = emptyBox();
  const byKey = new Map<string, Plate>();
  for (const h of grid.hexes) {
    const corners = worldCorners(grid, h);
    corners.forEach((p) => grow(bounds, p));
    const key = blockKey(h);
    for (let l = 0; l <= levelOf.get(h.id)!; l++) {
      const k = `${l}/${key}`;
      let plate = byKey.get(k);
      if (!plate) byKey.set(k, (plate = { level: l, block: key, hexes: [], box: emptyBox() }));
      plate.hexes.push(h);
      corners.forEach((p) => grow(plate!.box, p));
    }
  }
  const plates = [...byKey.values()].sort((a, b) => a.level - b.level || a.block.localeCompare(b.block));
  return { geometry, grid, hexById, levels, levelOf, plates, bounds };
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

/**
 * Colour of a hex on a plate below its top: the rim between two levels. The sea plate under land
 * is the coast (map.landLow), higher plates use the top colour; both shaded by wallShade.
 */
export function rimColor(hex: MapHex, gridHex: GridHex, level: number, map: MapColors, bounds: Box, wallShade: number): number {
  const base = level === 0 ? map.landLow : topColor(hex, gridHex, map, bounds);
  return shade(base, wallShade);
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
