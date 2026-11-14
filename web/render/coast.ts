// Soft coast (#100): the land mass as the union of the land hexes, its outline smoothed. Pure
// geometry, no PixiJS (the layer module turns it into Graphics, the tests check it under
// `node --test`). Flat map only (camera.pitch 0, #299): the coast lies in the land plane, there
// is no wall.
//
// Steps: (1) boundary edges of the land hexes chained into closed rings (outer rings and holes);
// (2) edges on the map border stay straight and pinned (nothing is rounded off where the board
// ends); (3) every other edge is subdivided, its inner points are moved along the outward normal
// by a deterministic noise of the world position (`coastNoise`), then (4) Chaikin corner cutting
// with ratio `coastRound`, two rounds. The contour never leaves the hex grid by more than
// COAST_MAX_DEV side lengths, so every hex stays readable as land or sea.
import { worldCorners, type Vec } from "./projection.ts";
import type { Scene } from "./scene.ts";

/** Largest allowed distance of the smoothed contour from the raw hex contour, in side lengths. */
export const COAST_MAX_DEV = 0.3;
/** Chaikin rounds and subdivision points per edge. */
export const CHAIKIN_ROUNDS = 2;
const SUBDIVIDE = 3;
/** Size of the noise features in side lengths (one lattice cell). */
const NOISE_CELL = 0.8;

export interface CoastParams {
  /** Chaikin cut ratio 0..0.5 (0 = hard hex outline). */
  round: number;
  /** Noise amplitude in side lengths (0 = none). */
  noise: number;
}

export interface Ring {
  /** Raw hex contour (corner points only) and its smoothed version, closed (first point not repeated). */
  raw: Vec[];
  points: Vec[];
  /** Lake or other water enclosed by land. */
  hole: boolean;
  /** Per raw edge i (raw[i] to raw[i+1]): lies on the map border, not on a coast. */
  border: boolean[];
}

const key = (p: Vec) => `${Math.round(p.x * 1000)},${Math.round(p.y * 1000)}`;

function area(ps: Vec[]): number {
  let s = 0;
  for (let i = 0; i < ps.length; i++) {
    const a = ps[i]!, b = ps[(i + 1) % ps.length]!;
    s += a.x * b.y - b.x * a.y;
  }
  return s / 2;
}

/** Deterministic value noise in -1..1 at a world position. */
export function coastNoise(x: number, y: number): number {
  const h = (i: number, j: number) => {
    let n = (Math.imul(i, 374761393) + Math.imul(j, 668265263)) | 0;
    n = Math.imul(n ^ (n >>> 13), 1274126177);
    return (((n ^ (n >>> 16)) >>> 0) / 4294967295) * 2 - 1;
  };
  const u = x / NOISE_CELL, v = y / NOISE_CELL;
  const i = Math.floor(u), j = Math.floor(v);
  const fu = u - i, fv = v - j;
  const s = (t: number) => t * t * (3 - 2 * t);
  const a = h(i, j), b = h(i + 1, j), c = h(i, j + 1), d = h(i + 1, j + 1);
  const top = a + (b - a) * s(fu), bot = c + (d - c) * s(fu);
  return top + (bot - top) * s(fv);
}

/** Is the hex a land hex (top above the sea)? */
const isLand = (scene: Scene, id: string) => (scene.levelOf.get(id) ?? 0) > 0;

/** Chaikin corner cutting of an open polyline (ends stay) or a closed ring. */
export function chaikin(ps: Vec[], r: number, rounds: number, closed: boolean): Vec[] {
  let cur = ps;
  for (let k = 0; k < rounds && r > 0; k++) {
    const out: Vec[] = [];
    const n = cur.length;
    const last = closed ? n : n - 1;
    if (!closed) out.push(cur[0]!);
    for (let i = 0; i < last; i++) {
      const a = cur[i]!, b = cur[(i + 1) % n]!;
      const first = !closed && i === 0, final = !closed && i === last - 1;
      if (!first) out.push({ x: a.x + (b.x - a.x) * r, y: a.y + (b.y - a.y) * r });
      if (!final) out.push({ x: b.x - (b.x - a.x) * r, y: b.y - (b.y - a.y) * r });
    }
    if (!closed) out.push(cur[n - 1]!);
    cur = out;
  }
  return cur;
}

/** Smooth a ring of corner points. `outward` is the sign of the outward normal (see landRings). */
export function smoothRing(raw: Vec[], border: boolean[], params: CoastParams, outward: number): Vec[] {
  const n = raw.length;
  if (params.round <= 0 && params.noise <= 0) return raw.map((p) => ({ ...p }));
  // Rotate so that the ring starts at the start of a border run (or anywhere when it has no border).
  let s = 0;
  if (border.some(Boolean)) {
    s = border.findIndex((b, i) => b && !border[(i + n - 1) % n]);
    if (s < 0) return raw.map((p) => ({ ...p })); // the whole ring is border
  }
  const out: Vec[] = [];
  let i = 0;
  while (i < n) {
    const e = (s + i) % n;
    if (border[e]) { out.push(raw[e]!); i++; continue; }
    // A run of coast edges e .. e+len-1: subdivide, displace, smooth as an open polyline.
    let len = 0;
    while (i + len < n && !border[(s + i + len) % n]) len++;
    const run: Vec[] = [];
    for (let k = 0; k < len; k++) {
      const a = raw[(s + i + k) % n]!, b = raw[(s + i + k + 1) % n]!;
      const ex = b.x - a.x, ey = b.y - a.y, el = Math.hypot(ex, ey) || 1;
      const nx = (ey / el) * outward, ny = (-ex / el) * outward;
      run.push(a);
      for (let m = 1; m < SUBDIVIDE; m++) {
        const px = a.x + (ex * m) / SUBDIVIDE, py = a.y + (ey * m) / SUBDIVIDE;
        const d = params.noise * coastNoise(px, py);
        run.push({ x: px + nx * d, y: py + ny * d });
      }
    }
    run.push(raw[(s + i + len) % n]!);
    const closed = border.every((b) => !b);
    const sm = chaikin(run, params.round, CHAIKIN_ROUNDS, false);
    if (closed) {
      // Whole ring is one coast run: it starts and ends at the same corner; smooth it as a closed ring instead.
      return chaikin(run.slice(0, -1), params.round, CHAIKIN_ROUNDS, true);
    }
    // A border edge pushes only its start, so the run's first point (= the border edge's end) is added here.
    out.push(...sm.slice(0, -1));
    i += len;
  }
  // The last point equals the first (closed by construction): drop the duplicate.
  const f = out[0]!, l = out[out.length - 1]!;
  if (out.length > 1 && Math.abs(f.x - l.x) < 1e-9 && Math.abs(f.y - l.y) < 1e-9) out.pop();
  return out;
}

/** Outline rings of the land mass, raw and smoothed. */
export function landRings(scene: Scene, params: CoastParams): Ring[] {
  type Edge = { a: Vec; b: Vec; border: boolean };
  const next = new Map<string, Edge>();
  let outward = 1;
  let orient = 0;
  for (const h of scene.grid.hexes) {
    if (!isLand(scene, h.id)) continue;
    const corners = worldCorners(scene.grid, h);
    if (!orient) {
      orient = Math.sign(area(corners)) || 1;
      // Outward normal of edge 0 (corner 5 to corner 0): (ey, -ex) is outward when it points away from the centre.
      const a = corners[5]!, b = corners[0]!;
      const nx = b.y - a.y, ny = -(b.x - a.x);
      outward = nx * ((a.x + b.x) / 2 - h.x) + ny * ((a.y + b.y) / 2 - h.y) >= 0 ? 1 : -1;
    }
    for (let i = 0; i < 6; i++) {
      const nid = h.neighbors[i];
      const n = nid ? scene.grid.byId.get(nid) : undefined;
      if (n && isLand(scene, n.id)) continue;
      const a = corners[(i + 5) % 6]!, b = corners[i]!;
      next.set(key(a), { a, b, border: !n });
    }
  }
  const rings: Ring[] = [];
  const done = new Set<string>();
  for (const [k0, e0] of next) {
    if (done.has(k0)) continue;
    const raw: Vec[] = [], border: boolean[] = [];
    let k = k0, e: Edge | undefined = e0;
    while (e && !done.has(k)) {
      done.add(k);
      raw.push(e.a);
      border.push(e.border);
      k = key(e.b);
      e = next.get(k);
    }
    if (raw.length < 3 || k !== k0) continue; // not a closed ring (malformed data)
    rings.push({ raw, border, points: smoothRing(raw, border, params, outward), hole: Math.sign(area(raw)) !== orient });
  }
  return rings;
}

/** Point in polygon (even-odd). */
export function inside(p: Vec, ring: Vec[]): boolean {
  let c = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const a = ring[i]!, b = ring[j]!;
    if ((a.y > p.y) !== (b.y > p.y) && p.x < ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y) + a.x) c = !c;
  }
  return c;
}

/** Outer rings with the holes (lakes) each one contains, for filling with cut-outs. */
export function landShapes(rings: Ring[]): { outer: Ring; holes: Ring[] }[] {
  const outers = rings.filter((r) => !r.hole).map((r) => ({ outer: r, holes: [] as Ring[], a: Math.abs(area(r.points)) }));
  for (const h of rings.filter((r) => r.hole)) {
    const host = outers.filter((o) => inside(h.points[0]!, o.outer.points)).sort((p, q) => p.a - q.a)[0];
    if (host) host.holes.push(h);
  }
  return outers.map(({ outer, holes }) => ({ outer, holes }));
}

/** Corner points of a hex scaled about its centre and rounded: one soft terrain blob. */
export function blob(scene: Scene, id: string, scale: number, round: number): Vec[] {
  const h = scene.grid.byId.get(id)!;
  const pts = worldCorners(scene.grid, h).map((c) => ({ x: h.x + (c.x - h.x) * scale, y: h.y + (c.y - h.y) * scale }));
  return chaikin(pts, round, CHAIKIN_ROUNDS, true);
}

/** Distance from a point to a closed polyline. */
export function distToRing(p: Vec, ring: Vec[]): number {
  let best = Infinity;
  for (let i = 0; i < ring.length; i++) {
    const a = ring[i]!, b = ring[(i + 1) % ring.length]!;
    const dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy;
    const t = l2 === 0 ? 0 : Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2));
    best = Math.min(best, Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)));
  }
  return best;
}
