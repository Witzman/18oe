// Camera projection and picking for the half-3D map (ui-spec 2.2, #143). Pure maths, no
// PixiJS: everything here runs under `node --test`.
//
// Spaces:
//   world   flat map plane from GET /map: hex centres x/y (side length 1, y down) and the
//           edge vectors. This file never derives a world position from row/column; the
//           only conversion is Oe::MapData.world on the server.
//   height  z in side lengths above the sea (mapdata.ts hexHeight).
//   screen  pixels. Orthographic oblique view, no vanishing point:
//             (x', y') = rotate (x - cx, y - cy) by yaw     (positive yaw turns the map clockwise)
//             sx = x'
//             sy = y' * cos(pitch) - z * sin(pitch)        (pitch 0 = straight from above)
//             screen = pan + zoom * (sx, sy)
//           For a fixed z that is an affine map (levelMatrix): one matrix per height level.

export interface Vec {
  x: number;
  y: number;
}

/** 2x3 affine matrix in PixiJS order: X = a*x + c*y + tx, Y = b*x + d*y + ty. */
export interface Affine {
  a: number;
  b: number;
  c: number;
  d: number;
  tx: number;
  ty: number;
}

export function apply(m: Affine, p: Vec): Vec {
  return { x: m.a * p.x + m.c * p.y + m.tx, y: m.b * p.x + m.d * p.y + m.ty };
}

export function invert(m: Affine): Affine {
  const det = m.a * m.d - m.b * m.c;
  if (Math.abs(det) < 1e-12) throw new Error("matrix not invertible (pitch 90 or zoom 0?)");
  const a = m.d / det, b = -m.b / det, c = -m.c / det, d = m.a / det;
  return { a, b, c, d, tx: -(a * m.tx + c * m.ty), ty: -(b * m.tx + d * m.ty) };
}

/** Camera: angles in degrees (theme camera.pitch / camera.yaw), zoom = px per side length. */
export interface View {
  pitch: number;
  yaw: number;
  zoom: number;
  /** Screen position of the world point (centerX, centerY) at height 0. */
  panX: number;
  panY: number;
  /** Rotation centre in world units (usually mapCenter). */
  centerX: number;
  centerY: number;
}

const RAD = Math.PI / 180;

/** World (flat, at height z) to screen, as one affine matrix: what a PixiJS level container gets. */
export function levelMatrix(view: View, z: number): Affine {
  const cy = Math.cos(view.yaw * RAD), sy = Math.sin(view.yaw * RAD);
  const cp = Math.cos(view.pitch * RAD), sp = Math.sin(view.pitch * RAD);
  const k = view.zoom;
  const a = k * cy, c = -k * sy, b = k * sy * cp, d = k * cy * cp;
  return {
    a, b, c, d,
    tx: view.panX - (a * view.centerX + c * view.centerY),
    ty: view.panY - (b * view.centerX + d * view.centerY) - k * z * sp,
  };
}

export function project(view: View, p: Vec, z: number): Vec {
  return apply(levelMatrix(view, z), p);
}

export function unproject(view: View, s: Vec, z: number): Vec {
  return apply(invert(levelMatrix(view, z)), s);
}

/** Depth along the view direction after the yaw rotation (larger = nearer the viewer). */
export function depth(view: View, p: Vec): number {
  const r = view.yaw * RAD;
  return Math.sin(r) * (p.x - view.centerX) + Math.cos(r) * (p.y - view.centerY);
}

// ---------------------------------------------------------------------------
// Hex shape from the edge vectors

export interface HexShape {
  /** Centre-to-neighbour vector per edge (from /map layout.edge_vectors). */
  edges: Vec[];
  /** Corner offsets from the centre; corner i lies between edge i and edge i+1. */
  corners: Vec[];
  /** Distance centre to corner (= side length). */
  radius: number;
}

/** Regular hex from the six centre-to-neighbour vectors; corner = (e_i + e_i+1) / 3. */
export function hexShape(edgeVectors: readonly (readonly [number, number])[]): HexShape {
  if (edgeVectors.length !== 6) throw new Error("expected six edge vectors");
  const edges = edgeVectors.map(([x, y]) => ({ x, y }));
  const len = Math.hypot(edges[0]!.x, edges[0]!.y);
  edges.forEach((e, i) => {
    const n = edges[(i + 1) % 6]!;
    const cos = (e.x * n.x + e.y * n.y) / (len * len);
    if (Math.abs(Math.hypot(e.x, e.y) - len) > 1e-4 || Math.abs(cos - 0.5) > 1e-4) {
      throw new Error(`edge vectors are not a regular hex in order (edge ${i})`);
    }
  });
  const corners = edges.map((e, i) => {
    const n = edges[(i + 1) % 6]!;
    return { x: (e.x + n.x) / 3, y: (e.y + n.y) / 3 };
  });
  return { edges, corners, radius: len / Math.sqrt(3) };
}

// ---------------------------------------------------------------------------
// The grid: hexes with their heights and a bucket index for lookups

export interface GridHex {
  id: string;
  x: number;
  y: number;
  /** Height of the top. */
  z: number;
  neighbors: (string | null)[];
}

export interface HexGrid {
  shape: HexShape;
  hexes: GridHex[];
  byId: Map<string, GridHex>;
  /** Highest top on the map. */
  maxZ: number;
  /** Distinct heights, descending. */
  levels: number[];
  cell: number;
  buckets: Map<number, GridHex[]>;
}

const EPS = 1e-9;
const key = (i: number, j: number) => i * 65536 + j;

export function buildGrid(
  hexes: readonly { id: string; x: number; y: number; neighbors: (string | null)[] }[],
  edgeVectors: readonly (readonly [number, number])[],
  heightOf: (id: string) => number,
): HexGrid {
  const shape = hexShape(edgeVectors);
  const cell = shape.radius;
  const list: GridHex[] = hexes.map((h) => ({ id: h.id, x: h.x, y: h.y, z: heightOf(h.id), neighbors: h.neighbors }));
  const buckets = new Map<number, GridHex[]>();
  for (const h of list) {
    const k = key(Math.floor(h.x / cell), Math.floor(h.y / cell));
    const b = buckets.get(k);
    if (b) b.push(h);
    else buckets.set(k, [h]);
  }
  const levels = [...new Set(list.map((h) => h.z))].sort((p, q) => q - p);
  return {
    shape, hexes: list, byId: new Map(list.map((h) => [h.id, h])),
    maxZ: levels[0] ?? 0, levels, cell, buckets,
  };
}

/** Hexes whose centre lies in the buckets covering the box (expanded by one hex radius). */
function candidates(grid: HexGrid, minX: number, minY: number, maxX: number, maxY: number): GridHex[] {
  const r = grid.shape.radius, c = grid.cell;
  const out: GridHex[] = [];
  for (let i = Math.floor((minX - r) / c); i <= Math.floor((maxX + r) / c); i++) {
    for (let j = Math.floor((minY - r) / c); j <= Math.floor((maxY + r) / c); j++) {
      const b = grid.buckets.get(key(i, j));
      if (b) for (const h of b) out.push(h);
    }
  }
  return out;
}

/** Is the world point inside (or on the border of, within tol) the hex? Three slabs between opposite edges. */
export function insideHex(grid: HexGrid, h: GridHex, p: Vec, tol = EPS): boolean {
  const dx = p.x - h.x, dy = p.y - h.y;
  for (let k = 0; k < 3; k++) {
    const e = grid.shape.edges[k]!;
    const t = (dx * e.x + dy * e.y) / (e.x * e.x + e.y * e.y);
    if (Math.abs(t) > 0.5 + tol) return false;
  }
  return true;
}

/** The hex containing a flat world point, or null (off the map). On a shared edge either side. */
export function hexAt(grid: HexGrid, p: Vec): GridHex | null {
  for (const h of candidates(grid, p.x, p.y, p.x, p.y)) if (insideHex(grid, h, p)) return h;
  return null;
}

// ---------------------------------------------------------------------------
// Picking: screen to hex

/**
 * The hex under a screen point: the first hex top or front wall the view ray meets
 * (ui-spec 2.2, step 2). The map is a height field with vertical walls; the ray through
 * a screen pixel is, on the ground plane, the segment p(z) = unproject(screen, z) for z
 * from maxZ down to 0. For every hex that segment crosses, the ray is inside the hex
 * column for z in [zLo, zHi]; it meets the hex if zLo <= top, at height min(zHi, top)
 * (top surface if zHi >= top, else its wall). The highest meeting point wins.
 *
 * This is the exact form of the spec's "descending height levels": testing only the
 * discrete levels can miss a column the ray crosses between two levels (near corners).
 * Upright objects (tokens, trains, map buttons; step 1) are not part of this file.
 */
export function pick(grid: HexGrid, view: View, s: Vec): GridHex | null {
  return pickWithHeight(grid, view, s)?.hex ?? null;
}

export function pickWithHeight(grid: HexGrid, view: View, s: Vec): { hex: GridHex; z: number } | null {
  const top = grid.maxZ;
  const p1 = unproject(view, s, 0);
  const p0 = top > 0 ? unproject(view, s, top) : p1; // p(z) = p1 + (p0 - p1) * z / top
  const dx = p0.x - p1.x, dy = p0.y - p1.y;
  let best: GridHex | null = null;
  let bestZ = -Infinity;
  const list = candidates(grid, Math.min(p0.x, p1.x), Math.min(p0.y, p1.y), Math.max(p0.x, p1.x), Math.max(p0.y, p1.y));
  for (const h of list) {
    // Clip t in [0, 1] (z = t * top) against the three slabs of h.
    let t0 = 0, t1 = 1;
    const ox = p1.x - h.x, oy = p1.y - h.y;
    for (let k = 0; k < 3 && t0 <= t1; k++) {
      const e = grid.shape.edges[k]!;
      const ee = e.x * e.x + e.y * e.y;
      const base = (ox * e.x + oy * e.y) / ee;
      const slope = (dx * e.x + dy * e.y) / ee;
      const lim = 0.5 + EPS;
      if (Math.abs(slope) < 1e-15) {
        if (Math.abs(base) > lim) t1 = -1;
        continue;
      }
      let a = (-lim - base) / slope, b = (lim - base) / slope;
      if (a > b) [a, b] = [b, a];
      if (a > t0) t0 = a;
      if (b < t1) t1 = b;
    }
    if (t0 > t1) continue;
    const zLo = t0 * top, zHi = t1 * top;
    if (zLo > h.z + EPS) continue;
    const z = Math.min(zHi, h.z);
    if (z > bestZ + EPS || (Math.abs(z - bestZ) <= EPS && best && h.z > best.z)) {
      best = h;
      bestZ = z;
    }
  }
  return best ? { hex: best, z: bestZ } : null;
}

// ---------------------------------------------------------------------------
// Polygons for drawing

/** Corners of a hex top in flat world coordinates (draw these into the level container). */
export function worldCorners(grid: HexGrid, h: GridHex): Vec[] {
  return grid.shape.corners.map((c) => ({ x: h.x + c.x, y: h.y + c.y }));
}

/** Corners of a hex top on screen. */
export function topPolygon(grid: HexGrid, view: View, h: GridHex): Vec[] {
  const m = levelMatrix(view, h.z);
  return worldCorners(grid, h).map((p) => apply(m, p));
}

export interface Wall {
  hex: GridHex;
  edge: number;
  /** Height of the wall foot: the lower neighbour's top, 0 at the map border. */
  bottom: number;
  /** Screen polygon: top corner A, top corner B, foot B, foot A. */
  polygon: Vec[];
  /** Sort key, back to front (ascending): depth of the edge midpoint. */
  depth: number;
}

/**
 * The visible walls of a hex: edges whose neighbour is lower (or missing) and whose
 * outward normal points to the viewer (down the screen). None at pitch 0.
 */
export function walls(grid: HexGrid, view: View, h: GridHex): Wall[] {
  const out: Wall[] = [];
  if (Math.abs(Math.sin(view.pitch * RAD)) < 1e-9) return out;
  const top = levelMatrix(view, h.z);
  const corners = worldCorners(grid, h);
  for (let i = 0; i < 6; i++) {
    const nid = h.neighbors[i];
    const bottom = nid ? (grid.byId.get(nid)?.z ?? 0) : 0;
    if (bottom >= h.z - EPS) continue;
    const e = grid.shape.edges[i]!;
    if (top.b * e.x + top.d * e.y <= 1e-9) continue; // faces away or edge-on
    const a = corners[(i + 5) % 6]!, b = corners[i]!;
    const foot = levelMatrix(view, bottom);
    out.push({
      hex: h, edge: i, bottom,
      polygon: [apply(top, a), apply(top, b), apply(foot, b), apply(foot, a)],
      depth: depth(view, { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }),
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Extent, for zoom and pan

export interface Box {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

/** Centre of the box around all hex centres (rotation centre of the map). */
export function mapCenter(grid: HexGrid): Vec {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const h of grid.hexes) {
    minX = Math.min(minX, h.x); maxX = Math.max(maxX, h.x);
    minY = Math.min(minY, h.y); maxY = Math.max(maxY, h.y);
  }
  return { x: (minX + maxX) / 2, y: (minY + maxY) / 2 };
}

/** Screen box around every hex top and every wall foot (ground level 0). */
export function screenBounds(grid: HexGrid, view: View): Box {
  const box = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
  const ground = levelMatrix(view, 0);
  const cache = new Map<number, Affine>();
  for (const h of grid.hexes) {
    let m = cache.get(h.z);
    if (!m) cache.set(h.z, (m = levelMatrix(view, h.z)));
    for (const p of worldCorners(grid, h)) {
      for (const s of [apply(m, p), apply(ground, p)]) {
        if (s.x < box.minX) box.minX = s.x;
        if (s.x > box.maxX) box.maxX = s.x;
        if (s.y < box.minY) box.minY = s.y;
        if (s.y > box.maxY) box.maxY = s.y;
      }
    }
  }
  return box;
}

/** Zoom and pan so the whole map fits a width x height viewport with a margin (key `0`). */
export function fitView(grid: HexGrid, view: View, width: number, height: number, margin = 0): View {
  const unit = { ...view, zoom: 1, panX: 0, panY: 0 };
  const b = screenBounds(grid, unit);
  const zoom = Math.min((width - 2 * margin) / (b.maxX - b.minX), (height - 2 * margin) / (b.maxY - b.minY));
  return {
    ...unit, zoom,
    panX: width / 2 - zoom * (b.minX + b.maxX) / 2,
    panY: height / 2 - zoom * (b.minY + b.maxY) / 2,
  };
}
