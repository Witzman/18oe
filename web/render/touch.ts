// Touch input helpers for the map (#259): pure functions, wired up in map.ts.
//   - tap candidates: which hexes lie within a finger's reach of a tap (ambiguity -> selection list)
//   - inertia: velocity of the last drag samples and its decay
// Distances are screen px; the reach comes from theme.shape.hitTouchPx (22 px radius = 44 px target).
import { project, type HexGrid, type Vec, type View } from "./projection.ts";

/** Hex ids whose on-screen centre lies within `reach` px of `s`, nearest first, at most `limit`. */
export function hexesNear(grid: HexGrid, view: View, s: Vec, reach: number, limit = 5): string[] {
  const out: { id: string; d: number }[] = [];
  for (const h of grid.hexes) {
    const p = project(view, { x: h.x, y: h.y }, h.z);
    const d = Math.hypot(p.x - s.x, p.y - s.y);
    if (d <= reach) out.push({ id: h.id, d });
  }
  return out.sort((a, b) => a.d - b.d).slice(0, limit).map((x) => x.id);
}

/**
 * Whether a tap on `picked` can be taken as it is: the hex is at least as wide as the finger target
 * (inner radius of a hex of side `zoom` is about 0.87 * zoom), so a finger cannot be on its neighbour.
 */
export function hexIsFingerSized(zoom: number, reach: number): boolean {
  return zoom * 0.866 >= reach;
}

export interface Sample { t: number; p: Vec }

/** Keeps the samples of the last `windowMs` ms. */
export function pushSample(samples: Sample[], s: Sample, windowMs = 100): Sample[] {
  return [...samples.filter((x) => s.t - x.t <= windowMs), s];
}

/** Release velocity in px/ms from the samples, {0,0} if too few or the finger rested before release. */
export function releaseVelocity(samples: Sample[], now: number, restMs = 60): Vec {
  const last = samples[samples.length - 1], first = samples[0];
  if (!last || !first || last === first || now - last.t > restMs) return { x: 0, y: 0 };
  const dt = last.t - first.t;
  if (dt <= 0) return { x: 0, y: 0 };
  return { x: (last.p.x - first.p.x) / dt, y: (last.p.y - first.p.y) / dt };
}

/** One inertia step: velocity v (px/ms) over dt ms with decay constant tau ms -> [displacement, new velocity]. */
export function inertiaStep(v: Vec, dt: number, tau: number): [Vec, Vec] {
  const k = Math.exp(-dt / tau);
  // Integral of v * exp(-t / tau) over dt.
  const move = tau * (1 - k);
  return [{ x: v.x * move, y: v.y * move }, { x: v.x * k, y: v.y * k }];
}

/** Below this speed (px/ms) inertia stops. */
export const INERTIA_STOP = 0.02;
