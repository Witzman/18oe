// Run bands (#155, ui-spec 2.9, view 1 "Planung"): the axis of a proposed run, assembled from the route the
// server offers in the Run step. Pure functions, no PixiJS, so `node --test` checks them; the drawing
// (band, rings, shields) is layers/runs.ts.
//
// Input is the route as the prompt's `run_routes` action carries it (D3a, lib/engine/route.rb): `connections`,
// the hex chain between two stops each (first and last hex hold the stop), and `nodes`, the stops in order
// as signatures "<hex>-<node index>". The prompt does NOT carry the entry and exit edge per hex (D3a asks for
// it; ui-data-needs.md names this client-side derivation as the fallback), so they are derived here:
// - a hex in the middle of a chain is entered from the neighbour before it and left towards the neighbour after
//   it (`neighbors` of /map: edge i points to neighbors[i]); the first and last hex of a chain are entered or
//   left at the stop node of that hex;
// - inside a hex the way from the entry to the exit is the shortest chain of track axes (track-axes.ts, #144),
//   so a through town (two halves), a ferry line of a sea hex and a plain curve all come out the same way.
// ASSUMPTIONS (a picture of the physical board does not settle them): the node index of a signature is the
// node number of the tile parts of /map; a route does not use a second, longer path between the same two
// ends of a tile (ambiguous only on tiles that have two paths between the same ends, none in the catalog).
// What cannot be resolved (hex without tile data, hexes that are not neighbours) is left out and listed in
// `unresolved`; the points around it are joined by a straight line and listed in `breaks`.
import { polyline } from "./axis-sample.ts";
import type { ZoomStage } from "./camera.ts";
import type { Axis, PathEnd, TileGeometry, Vec } from "./track-axes.ts";

/** What the run bands need from the map, by hex id. */
export interface RunWorld {
  neighbors(hex: string): readonly (string | null)[] | undefined;
  /** Axes and nodes of the tile on the hex (hex coordinates, centre at 0,0); null without tile data. */
  geometry(hex: string): TileGeometry | null;
  /** World position of the hex centre. */
  origin(hex: string): Vec | null;
}

/** The part of a `run_routes` route the band needs (see Prompt.actions). */
export interface RunRouteInput {
  train: string;
  connections: string[][];
  nodes: string[];
  revenue: number;
}

export interface RunStop { hex: string; node: number; at: Vec }

export interface RunLine {
  train: string;
  revenue: number;
  /** The axis of the run, world coordinates, in driving order; consecutive points are at most MAX_STEP apart except at `breaks`. */
  points: Vec[];
  /** The hex each point lies in (parallel to `points`; the shared edge point counts for the hex entered first). */
  hexes: string[];
  /** Indices i where the step from points[i - 1] to points[i] is a straight join over a gap, not track. */
  breaks: number[];
  stops: RunStop[];
  /** What could not be put on the track, one line each (hex ids). */
  unresolved: string[];
}

/** Maximum distance of two polyline points of an axis (ui-spec 2.6). */
export const MAX_STEP = 0.05;

const EPS = 1e-6;
const dist = (p: Vec, q: Vec): number => Math.hypot(p.x - q.x, p.y - q.y);
const key = (e: PathEnd): string => ("edge" in e ? `e${e.edge}` : `n${e.node}`);

/** "H21-0" -> { hex: "H21", node: 0 }; null for anything else. */
export function parseNode(signature: string): { hex: string; node: number } | null {
  const i = signature.lastIndexOf("-");
  if (i <= 0) return null;
  const node = Number(signature.slice(i + 1));
  return Number.isInteger(node) ? { hex: signature.slice(0, i), node } : null;
}

/** Edge of `hex` that faces `other`, or -1. */
function edgeToward(world: RunWorld, hex: string, other: string): number {
  return world.neighbors(hex)?.indexOf(other) ?? -1;
}

/** Shortest chain of axes from one end of the tile to the other (Dijkstra by length), each with its direction; null if unconnected. */
export function axisChain(geom: TileGeometry, from: PathEnd, to: PathEnd): { axis: Axis; reversed: boolean }[] | null {
  const start = key(from), goal = key(to);
  if (start === goal) return [];
  const best = new Map<string, { d: number; via?: { axis: Axis; reversed: boolean; prev: string } }>([[start, { d: 0 }]]);
  const todo = new Set([start]);
  while (todo.size) {
    let cur = "";
    for (const k of todo) if (cur === "" || best.get(k)!.d < best.get(cur)!.d) cur = k;
    todo.delete(cur);
    if (cur === goal) break;
    const d = best.get(cur)!.d;
    for (const axis of geom.axes) {
      for (const reversed of [false, true]) {
        const [u, w] = reversed ? [axis.b, axis.a] : [axis.a, axis.b];
        if (key(u) !== cur) continue;
        const next = key(w), nd = d + axis.length;
        if (!best.has(next) || nd < best.get(next)!.d - EPS) { best.set(next, { d: nd, via: { axis, reversed, prev: cur } }); todo.add(next); }
      }
    }
  }
  if (!best.has(goal)) return null;
  const out: { axis: Axis; reversed: boolean }[] = [];
  for (let k = goal; k !== start;) {
    const v = best.get(k)!.via!;
    out.unshift({ axis: v.axis, reversed: v.reversed });
    k = v.prev;
  }
  return out;
}

/** The run's axis (see the file header). `route.connections` empty or without resolvable hexes gives an empty line. */
export function routeLine(route: RunRouteInput, world: RunWorld): RunLine {
  const line: RunLine = { train: route.train, revenue: route.revenue, points: [], hexes: [], breaks: [], stops: [], unresolved: [] };
  const sigs = route.nodes.map(parseNode);
  const add = (pts: Vec[], hex: string) => {
    if (!pts.length) return;
    const last = line.points[line.points.length - 1];
    if (last && dist(last, pts[0]!) > EPS) line.breaks.push(line.points.length);
    const fresh = last && dist(last, pts[0]!) <= EPS ? pts.slice(1) : pts;
    line.points.push(...fresh);
    line.hexes.push(...fresh.map(() => hex));
  };
  const stopAt = (sig: { hex: string; node: number } | null | undefined) => {
    if (!sig) return;
    const geom = world.geometry(sig.hex), o = world.origin(sig.hex);
    const n = geom?.nodes.find((x) => x.node === sig.node);
    if (n && o) line.stops.push({ hex: sig.hex, node: sig.node, at: { x: o.x + n.pos.x, y: o.y + n.pos.y } });
    else line.unresolved.push(`${sig.hex}-${sig.node}`);
  };
  for (const s of sigs) stopAt(s);

  route.connections.forEach((chain, k) => {
    const hexes = chain.filter((h) => h !== "local");
    hexes.forEach((hex, i) => {
      const geom = world.geometry(hex), o = world.origin(hex);
      if (!geom || !o) { line.unresolved.push(hex); return; }
      const first = i === 0, last = i === hexes.length - 1;
      const at = (sig: { hex: string; node: number } | null | undefined): PathEnd | null => (sig && sig.hex === hex ? { node: sig.node } : null);
      const toward = (other: string): PathEnd | null => { const e = edgeToward(world, hex, other); return e >= 0 ? { edge: e } : null; };
      const enter = first ? at(sigs[k]) : toward(hexes[i - 1]!);
      const exit = last ? at(sigs[k + 1]) : toward(hexes[i + 1]!);
      const steps = enter && exit ? axisChain(geom, enter, exit) : null;
      if (!steps) { line.unresolved.push(hex); return; }
      for (const { axis, reversed } of steps) {
        const pts = polyline(axis, MAX_STEP, o).map((p) => ({ x: p.x, y: p.y }));
        add(reversed ? pts.reverse() : pts, hex);
      }
    });
  });
  return line;
}

/** Sideways offsets of n trains in side lengths, centred on the track: one train 0, two -gap/2 and +gap/2, ... */
export function runOffsets(n: number, gap: number): number[] {
  return Array.from({ length: n }, (_, i) => (i - (n - 1) / 2) * gap);
}

/** The polyline moved `d` along its left normal (tangent from the neighbouring points); ends and breaks keep their direction. */
export function offsetPoints(points: readonly Vec[], d: number, breaks: readonly number[] = []): Vec[] {
  if (d === 0) return points.map((p) => ({ ...p }));
  const cut = new Set(breaks);
  return points.map((p, i) => {
    // do not take the tangent across a break: use the one-sided direction instead
    const a = i > 0 && !cut.has(i) ? points[i - 1]! : p;
    const b = i < points.length - 1 && !cut.has(i + 1) ? points[i + 1]! : p;
    const n = dist(a, b);
    if (n < EPS) return { ...p };
    return { x: p.x - ((b.y - a.y) / n) * d, y: p.y + ((b.x - a.x) / n) * d };
  });
}

/** What the zoom stages show (owner decision 2026-11-19): the band always, the stop rings with revenue from Z1, the shields from Z2. */
export function runVisibility(stage: ZoomStage): { band: boolean; rings: boolean; shields: boolean } {
  return { band: true, rings: stage >= 1, shields: stage >= 2 };
}
