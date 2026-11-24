// Base surfaces (#477): the sea gets lighter towards the coast and the coast a foam fringe. Both are
// stacks of strokes along the smoothed land rings (coast.ts), computed once per map and theme, drawn into
// the static sea and land layers and cached as textures (#599: as strokes they cost seconds per frame under software
// rendering), so they cost little per frame and show at every zoom stage. Pure numbers
// here (no PixiJS), the layer module turns them into strokes.

/** Strokes in the sea gradient; more means smoother, each one is one more pass over the ring points. */
export const SEA_BAND_COUNT = 14;

export interface Band {
  /** Stroke width in hex side lengths (centred on the coast line, so half of it lies in the sea). */
  width: number;
  alpha: number;
}

/**
 * Sea gradient by distance to the coast: `count` strokes, widest first, each an opaque colour (a stroke with alpha
 * would blend twice where it overlaps itself at a bend). `amount` is how far the sea colour is mixed towards the
 * coast tint in that ring (rises from the outer ring to the last one, `total` at the coast, 0 at `reach` side
 * lengths into the sea), so one stack serves each sea: mix(seaColour, tint, amount).
 */
export function seaBands(reach: number, total: number, count = SEA_BAND_COUNT): Band[] {
  if (reach <= 0 || total <= 0) return [];
  return Array.from({ length: count }, (_, i) => ({ width: (2 * reach * (count - i)) / count, alpha: (total * (i + 0.5)) / count }));
}

/** Foam fringe along the coast, outer (wide, faint) to inner (thin, strong); `width` is the outer reach in side lengths. */
export function foamLayers(width: number, alpha: number): Band[] {
  if (width <= 0 || alpha <= 0) return [];
  return [
    { width: width * 2, alpha: alpha * 0.25 },
    { width: width * 1.1, alpha: alpha * 0.5 },
    { width: width * 0.4, alpha },
  ];
}

import type { Ring } from "./coast.ts";
import type { Vec } from "./projection.ts";

const k = (p: Vec) => `${Math.round(p.x * 1000)},${Math.round(p.y * 1000)}`;

export interface Run {
  points: Vec[];
  /** A whole ring without map border: drawn as a closed polygon. */
  closed: boolean;
}

/**
 * The coast parts of a ring as polylines: the sides on the map border are cut out (a stroke there would paint the
 * background outside the board). smoothRing keeps the corners of border sides exactly and inserts at least two other
 * points into every coast run, so a segment between two such corners is a border side.
 */
export function coastRuns(ring: Ring): Run[] {
  if (!ring.border.some(Boolean)) return [{ points: ring.points, closed: true }];
  const corners = new Set<string>();
  ring.raw.forEach((p, i) => { if (ring.border[i]) { corners.add(k(p)); corners.add(k(ring.raw[(i + 1) % ring.raw.length]!)); } });
  const pts = ring.points, n = pts.length;
  const isBorder = (i: number) => corners.has(k(pts[i]!)) && corners.has(k(pts[(i + 1) % n]!));
  const start = [...pts.keys()].find((i) => isBorder((i + n - 1) % n) && !isBorder(i));
  if (start === undefined) return [];
  const runs: Run[] = [];
  let cur: Vec[] = [];
  for (let m = 0; m < n; m++) {
    const i = (start + m) % n;
    cur.push(pts[i]!);
    if (isBorder(i)) { if (cur.length > 1) runs.push({ points: cur, closed: false }); cur = []; }
  }
  if (cur.length > 1) runs.push({ points: [...cur, pts[start]!], closed: false });
  return runs;
}

/**
 * Douglas-Peucker: the polyline without the points that lie within `tol` of the line through their neighbours. The wide
 * soft strokes of the sea gradient need no more detail than that, and tessellating them is the cost of building the map.
 */
export function simplify(ps: Vec[], tol: number): Vec[] {
  if (ps.length < 3 || tol <= 0) return ps;
  const keep = new Array<boolean>(ps.length).fill(false);
  keep[0] = keep[ps.length - 1] = true;
  const stack: [number, number][] = [[0, ps.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop()!;
    const p = ps[a]!, q = ps[b]!;
    const dx = q.x - p.x, dy = q.y - p.y, l2 = dx * dx + dy * dy;
    let worst = -1, at = -1;
    for (let i = a + 1; i < b; i++) {
      const r = ps[i]!;
      const t = l2 === 0 ? 0 : Math.max(0, Math.min(1, ((r.x - p.x) * dx + (r.y - p.y) * dy) / l2));
      const d = Math.hypot(r.x - (p.x + t * dx), r.y - (p.y + t * dy));
      if (d > worst) { worst = d; at = i; }
    }
    if (worst > tol && at > 0) { keep[at] = true; stack.push([a, at], [at, b]); }
  }
  return ps.filter((_, i) => keep[i]);
}
