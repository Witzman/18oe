// Points and tangents along a track axis by distance (#144): sleepers and rails of
// the track picture (#146), route bands, and the train animation (#157). Pure
// functions over the curves of track-axes.ts, no PixiJS.
import { BEZIER_STEPS, add, curvePoint, curveTangent, type Axis, type Curve, type Vec } from "./track-axes.ts";

export interface AxisSample {
  /** Distance from the axis start (end `a`). */
  s: number;
  x: number;
  y: number;
  /** Unit tangent in the direction a -> b. */
  tx: number;
  ty: number;
}

// Cumulative chord lengths of a Bezier at BEZIER_STEPS parameter steps, cached per curve.
const tables = new WeakMap<Curve, Float64Array>();

function bezierTable(c: Curve): Float64Array {
  let t = tables.get(c);
  if (!t) {
    t = new Float64Array(BEZIER_STEPS + 1);
    let prev = curvePoint(c, 0);
    for (let i = 1; i <= BEZIER_STEPS; i++) {
      const p = curvePoint(c, i / BEZIER_STEPS);
      t[i] = t[i - 1]! + Math.hypot(p.x - prev.x, p.y - prev.y);
      prev = p;
    }
    tables.set(c, t);
  }
  return t;
}

/** Curve parameter at distance `s` along the curve (`s` within [0, length]). */
function paramAt(axis: Axis, s: number): number {
  const c = axis.curve;
  if (c.kind !== "bezier") return s / axis.length;
  const table = bezierTable(c);
  const total = table[BEZIER_STEPS]!;
  const target = (s / axis.length) * total; // axis.length was measured with the same table
  let lo = 0;
  let hi = BEZIER_STEPS;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (table[mid]! < target) lo = mid;
    else hi = mid;
  }
  const span = table[hi]! - table[lo]!;
  const f = span > 0 ? (target - table[lo]!) / span : 0;
  return (lo + f) / BEZIER_STEPS;
}

/**
 * Point and tangent at distance `s` from the start of the axis, clamped to
 * [0, length]. `origin` (the hex centre in world coordinates) is added to the point.
 */
export function pointAt(axis: Axis, s: number, origin: Vec = { x: 0, y: 0 }): AxisSample {
  const d = Math.min(Math.max(s, 0), axis.length);
  const t = paramAt(axis, d);
  const p = add(curvePoint(axis.curve, t), origin);
  const tan = curveTangent(axis.curve, t);
  return { s: d, x: p.x, y: p.y, tx: tan.x, ty: tan.y };
}

/**
 * Samples every `spacing` along the axis, starting at `offset` (default: half a
 * spacing, so sleepers sit symmetric and two axes meeting at an edge do not put
 * two sleepers on the same spot).
 */
export function samplesEvery(axis: Axis, spacing: number, offset = spacing / 2, origin?: Vec): AxisSample[] {
  if (!(spacing > 0)) throw new Error("spacing must be positive");
  const out: AxisSample[] = [];
  for (let s = offset; s <= axis.length + 1e-9; s += spacing) out.push(pointAt(axis, s, origin));
  return out;
}

/** Polyline through the axis with at most `maxStep` between points (ui-spec 2.6: 0.05), ends included. */
export function polyline(axis: Axis, maxStep = 0.05, origin?: Vec): AxisSample[] {
  if (!(maxStep > 0)) throw new Error("maxStep must be positive");
  const n = Math.max(1, Math.ceil(axis.length / maxStep));
  return Array.from({ length: n + 1 }, (_, i) => pointAt(axis, (axis.length * i) / n, origin));
}
