// Track axes (#144, ui-spec 2.6): the centre line of every tile path as a geometric
// curve in hex coordinates. Pure functions, no PixiJS, so `node --test` checks them.
//
// Input is the structured tile parts of GET /map (#43, lib/oe/map_data.rb): `paths`
// with ends `{edge}` or `{node}` (+ `terminal`), the nodes (`cities`, `towns`,
// `double_towns`, `offboards`, `junction`), and the tile rotation. Edge directions
// are NOT assumed here: `hexFrame` builds them from `layout.edge_vectors` of /map
// (edge i points to neighbors[i]; the server derives them from the engine).
//
// Hex coordinates: origin at the hex centre, same orientation and unit as the flat
// world of /map (side length 1 there, y down). Add the hex centre (x, y) for world
// coordinates. Every axis runs from its path's end `a` to end `b`; tangents are unit
// vectors in that direction of travel. Track drawing (#146), route bands and the
// train animation (#157) all sample these curves (axis-sample.ts).
//
// Placement rules and their status (spec rule, or ASSUMPTION = best guess, checked
// only by the unit tests, not against a picture of the physical tiles):
// - Edge to edge: distance 3 straight, 2 wide arc (radius 1.5 s, centre = centre of
//   the neighbour hex between both edges), 1 sharp arc (radius 0.5 s, centre = the
//   shared corner). Spec. All three leave an edge perpendicular to it.
// - Edge to node: quadratic Bezier from the edge midpoint M to the node, control
//   point M - u * d/2 (u = outward edge direction, d = |node - M|). Spec.
// - Node to node: straight line. Spec.
// - `terminal`: geometry like edge to node; the flag is passed through, the taper
//   (last 30 %) is drawing (#146). Spec.
// - Node position: explicit `loc` first (engine: (loc + rotation) mod 6, an edge
//   position, fractions are corners) at NODE_OFFSET from the centre; else a single
//   node sits in the centre; else the centroid of the edge midpoints it connects to,
//   set to NODE_OFFSET. Spec, with the offset for `loc` an ASSUMPTION.
// - ASSUMPTION (refines the spec): a single plain town with exactly two edge paths
//   (tiles 3, 4, 58; printed X79) sits ON the edge-to-edge curve at its midpoint;
//   its two axes are the two halves of that curve, so the track runs through the
//   town without a kink (that is how 18xx tiles show a town on a through track).
// - ASSUMPTION: when the centroid rule degenerates (a node on a straight through
//   track in a multi-node tile, OE12/OE13: all three cities would land in the
//   centre), the node goes to the engine's preferred edge (a port of
//   Engine::Tile#compute_city_town_edges, which the old tobymao renderer used),
//   always one of the node's own exits, at NODE_OFFSET.
// - Nodes without paths (printed K26 Birmingham, C74, the second city of AA82):
//   with exactly two nodes, opposite the other one (engine rule); otherwise spread
//   evenly over the edge directions index * 6 / n (engine rule), at NODE_OFFSET.
// - Double towns (`double_town`, OE1-OE3, OE9-OE11, OE20-OE22, printed C58 ...):
//   one node in the centre (input/decisions.md ADR-012: a "centered double town",
//   all paths end at one node), every path a spoke to the centre. ASSUMPTION: the
//   two town marks lie at +-DOUBLE_TOWN_MARK along `axis` read as an edge position
//   (like `loc`: (axis + rotation), fractions are corners). What `axis` means in
//   the old renderer is not documented in input/; open question on #43.

export interface Vec { x: number; y: number }

export type PathEnd = { edge: number } | { node: number };

export interface TilePath { a: PathEnd; b: PathEnd; terminal?: boolean }

/** The track-relevant parts of a tile or printed hex, as GET /map delivers them. */
export interface TileParts {
  cities?: { node: number; slots?: number; loc?: string | number }[];
  towns?: { node: number; loc?: string | number }[];
  double_towns?: { node: number; axis: number; revenue_loc?: number[] }[];
  offboards?: { node: number }[];
  junction?: number;
  paths?: TilePath[];
}

export type Curve =
  | { kind: "line"; p0: Vec; p1: Vec }
  /** Angles in radians in hex coordinates (y down); the arc runs from `start` over `sweep`. */
  | { kind: "arc"; center: Vec; radius: number; start: number; sweep: number }
  | { kind: "bezier"; p0: Vec; c: Vec; p1: Vec };

export type AxisShape = "straight" | "wideArc" | "sharpArc" | "toNode" | "throughTown" | "nodeToNode";

export interface Axis {
  /** Index of the path in `parts.paths`: one axis per path, same order. */
  path: number;
  /** Ends after rotation (edge numbers rotated, node indices unchanged). */
  a: PathEnd;
  b: PathEnd;
  terminal: boolean;
  shape: AxisShape;
  curve: Curve;
  start: Vec;
  end: Vec;
  /** Unit tangents in the direction a -> b. */
  startTangent: Vec;
  endTangent: Vec;
  length: number;
}

export type NodeKind = "city" | "town" | "double_town" | "offboard" | "junction";
export type Placement = "loc" | "center" | "exits" | "engineEdge" | "pathless" | "throughTown";

export interface NodeGeom {
  node: number;
  kind: NodeKind;
  pos: Vec;
  placement: Placement;
  /** Double towns only: the two town marks. */
  marks?: [Vec, Vec];
  /** Double towns only: revenue positions as rotated edge positions (0..6). */
  revenueLoc?: number[];
}

export interface TileGeometry { nodes: NodeGeom[]; axes: Axis[] }

export interface HexFrame {
  /** Outward unit direction of edge 0..5. */
  unit: Vec[];
  /** Centre to edge midpoint. */
  inradius: number;
  /** Side length = centre to corner. */
  side: number;
}

/** Node distance from the centre for off-centre nodes, as a fraction of the inradius (spec: 45 %). */
export const NODE_OFFSET = 0.45;
/** Double town marks: distance from the centre in side lengths. ASSUMPTION. */
export const DOUBLE_TOWN_MARK = 0.25;

const EPS = 1e-9;

export const add = (p: Vec, q: Vec): Vec => ({ x: p.x + q.x, y: p.y + q.y });
export const sub = (p: Vec, q: Vec): Vec => ({ x: p.x - q.x, y: p.y - q.y });
export const scale = (p: Vec, k: number): Vec => ({ x: p.x * k, y: p.y * k });
export const dot = (p: Vec, q: Vec): number => p.x * q.x + p.y * q.y;
export const cross = (p: Vec, q: Vec): number => p.x * q.y - p.y * q.x;
export const norm = (p: Vec): number => Math.hypot(p.x, p.y);
export function unit(p: Vec): Vec {
  const n = norm(p);
  if (n < EPS) throw new Error("zero vector has no direction");
  return scale(p, 1 / n);
}

/** Signed angle difference b - a, normalised to (-pi, pi]. */
function angleDelta(a: number, b: number): number {
  let d = (b - a) % (2 * Math.PI);
  if (d <= -Math.PI) d += 2 * Math.PI;
  if (d > Math.PI) d -= 2 * Math.PI;
  return d;
}

/**
 * The six edge directions from /map `layout.edge_vectors` (centre to neighbour
 * centre per edge). Checks they form a regular hexagon: equal length, consecutive
 * edges 60 degrees apart, all turning the same way.
 */
export function hexFrame(edgeVectors: readonly (readonly number[])[]): HexFrame {
  if (edgeVectors.length !== 6) throw new Error(`expected 6 edge vectors, got ${edgeVectors.length}`);
  const v = edgeVectors.map(([x, y]) => ({ x: Number(x), y: Number(y) }));
  const len = norm(v[0]!);
  const steps = v.map((p, i) => angleDelta(Math.atan2(p.y, p.x), Math.atan2(v[(i + 1) % 6]!.y, v[(i + 1) % 6]!.x)));
  for (const [i, p] of v.entries()) {
    if (Math.abs(norm(p) - len) > 1e-4 * len) throw new Error(`edge vector ${i} has another length`);
    if (Math.abs(Math.abs(steps[i]!) - Math.PI / 3) > 1e-4 || Math.sign(steps[i]!) !== Math.sign(steps[0]!)) {
      throw new Error(`edge vectors ${i} and ${(i + 1) % 6} are not 60 degrees apart in one turning sense`);
    }
  }
  const inradius = len / 2;
  return { unit: v.map(unit), inradius, side: (2 * inradius) / Math.sqrt(3) };
}

const mod6 = (n: number): number => ((n % 6) + 6) % 6;

/** Midpoint of edge `edge` (already rotated). */
export function edgeMidpoint(frame: HexFrame, edge: number): Vec {
  return scale(frame.unit[mod6(edge)]!, frame.inradius);
}

/** Unit direction of an edge position (fractions are corners), e.g. `loc` 4.5. */
export function edgePositionDirection(frame: HexFrame, position: number): Vec {
  const p = ((position % 6) + 6) % 6;
  const i = Math.floor(p);
  const f = p - i;
  const u0 = frame.unit[i % 6]!;
  const u1 = frame.unit[(i + 1) % 6]!;
  const a0 = Math.atan2(u0.y, u0.x);
  const theta = a0 + f * angleDelta(a0, Math.atan2(u1.y, u1.x));
  return { x: Math.cos(theta), y: Math.sin(theta) };
}

// ---------------------------------------------------------------- curve maths

export function curvePoint(c: Curve, t: number): Vec {
  switch (c.kind) {
    case "line":
      return add(c.p0, scale(sub(c.p1, c.p0), t));
    case "arc": {
      const th = c.start + c.sweep * t;
      return { x: c.center.x + c.radius * Math.cos(th), y: c.center.y + c.radius * Math.sin(th) };
    }
    case "bezier": {
      const s = 1 - t;
      return {
        x: s * s * c.p0.x + 2 * s * t * c.c.x + t * t * c.p1.x,
        y: s * s * c.p0.y + 2 * s * t * c.c.y + t * t * c.p1.y,
      };
    }
  }
}

/** Unit tangent at parameter t in the direction of increasing t. */
export function curveTangent(c: Curve, t: number): Vec {
  switch (c.kind) {
    case "line":
      return unit(sub(c.p1, c.p0));
    case "arc": {
      const th = c.start + c.sweep * t;
      const s = Math.sign(c.sweep);
      return { x: -Math.sin(th) * s, y: Math.cos(th) * s };
    }
    case "bezier": {
      const d = add(scale(sub(c.c, c.p0), 2 * (1 - t)), scale(sub(c.p1, c.c), 2 * t));
      // A degenerate end (control point on the end point) falls back to the chord.
      return norm(d) > EPS ? unit(d) : unit(sub(c.p1, c.p0));
    }
  }
}

/** Bezier samples for the arc-length table (64 chords: error far below 1e-4 for these short curves). */
export const BEZIER_STEPS = 64;

export function curveLength(c: Curve): number {
  switch (c.kind) {
    case "line":
      return norm(sub(c.p1, c.p0));
    case "arc":
      return Math.abs(c.sweep) * c.radius;
    case "bezier": {
      let len = 0;
      let prev = c.p0;
      for (let i = 1; i <= BEZIER_STEPS; i++) {
        const p = curvePoint(c, i / BEZIER_STEPS);
        len += norm(sub(p, prev));
        prev = p;
      }
      return len;
    }
  }
}

function reverse(c: Curve): Curve {
  switch (c.kind) {
    case "line":
      return { kind: "line", p0: c.p1, p1: c.p0 };
    case "arc":
      return { ...c, start: c.start + c.sweep, sweep: -c.sweep };
    case "bezier":
      return { kind: "bezier", p0: c.p1, c: c.c, p1: c.p0 };
  }
}

/** The part of `c` from parameter 0 to `t` (lines and arcs only). */
function head(c: Curve, t: number): Curve {
  if (c.kind === "line") return { kind: "line", p0: c.p0, p1: curvePoint(c, t) };
  if (c.kind === "arc") return { ...c, sweep: c.sweep * t };
  throw new Error("head() of a Bezier is not needed");
}

function arcThrough(center: Vec, from: Vec, to: Vec): Curve {
  const start = Math.atan2(from.y - center.y, from.x - center.x);
  const stop = Math.atan2(to.y - center.y, to.x - center.x);
  return { kind: "arc", center, radius: norm(sub(from, center)), start, sweep: angleDelta(start, stop) };
}

/** Edge-to-edge centre line from edge `a` to edge `b` (both rotated). */
export function edgeToEdge(frame: HexFrame, a: number, b: number): { curve: Curve; shape: AxisShape } {
  const ma = edgeMidpoint(frame, a);
  const mb = edgeMidpoint(frame, b);
  const diff = mod6(b - a);
  const dist = Math.min(diff, 6 - diff);
  const ua = frame.unit[mod6(a)]!;
  const ub = frame.unit[mod6(b)]!;
  if (dist === 3) return { curve: { kind: "line", p0: ma, p1: mb }, shape: "straight" };
  if (dist === 2) {
    // u[a] + u[b] is the unit direction of the hex between both edges, 2 * inradius away.
    return { curve: arcThrough(scale(add(ua, ub), 2 * frame.inradius), ma, mb), shape: "wideArc" };
  }
  if (dist === 1) {
    // The shared corner: circumradius (= side) in the direction between both edges.
    return { curve: arcThrough(scale(unit(add(ua, ub)), frame.side), ma, mb), shape: "sharpArc" };
  }
  throw new Error(`path from edge ${a} to the same edge`);
}

function edgeToPoint(frame: HexFrame, edge: number, p: Vec): Curve {
  const m = edgeMidpoint(frame, edge);
  const d = norm(sub(p, m));
  return { kind: "bezier", p0: m, c: sub(m, scale(frame.unit[mod6(edge)]!, d / 2)), p1: p };
}

// ---------------------------------------------------------------- nodes

function nodeKinds(parts: TileParts): Map<number, { kind: NodeKind; loc?: string | number }> {
  const out = new Map<number, { kind: NodeKind; loc?: string | number }>();
  for (const c of parts.cities ?? []) out.set(c.node, { kind: "city", loc: c.loc });
  for (const t of parts.towns ?? []) out.set(t.node, { kind: "town", loc: t.loc });
  for (const d of parts.double_towns ?? []) out.set(d.node, { kind: "double_town" });
  for (const o of parts.offboards ?? []) out.set(o.node, { kind: "offboard" });
  if (parts.junction !== undefined) out.set(parts.junction, { kind: "junction" });
  for (const p of parts.paths ?? []) {
    for (const e of [p.a, p.b]) {
      if ("node" in e && !out.has(e.node)) throw new Error(`path refers to unknown node ${e.node}`);
    }
  }
  return out;
}

function locNumber(loc: string | number | undefined): number | null {
  if (loc === undefined || loc === "center") return null;
  const n = Number(loc);
  if (!Number.isFinite(n)) throw new Error(`unsupported loc ${String(loc)}`);
  return n;
}

/**
 * Port of Engine::Tile#compute_city_town_edges for nodes with exits (lib/engine/tile.rb):
 * per node the preferred edge, chosen among its exits by the lowest usage count
 * (each exit +1, its neighbours +0.1, edge 0 +0.1 to keep room for the name).
 * Only used as the fallback for the degenerate centroid case.
 */
function enginePreferredEdges(exits: Map<number, number[]>, locs: Map<number, number>): Map<number, number> {
  const count = new Array<number>(6).fill(0);
  count[0]! += 0.1;
  const bump = (e: number): void => {
    count[e]! += 1;
    count[mod6(e + 1)]! += 0.1;
    count[mod6(e - 1)]! += 0.1;
  };
  for (const es of exits.values()) es.forEach(bump);
  const order = [...exits.entries()]
    .map(([n, es]) => [n, [...es].sort((x, y) => x - y)] as const)
    .sort(([, x], [, y]) => {
      for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i]! - y[i]!;
      return x.length - y.length;
    });
  const out = new Map<number, number>();
  for (const [n, es] of order) {
    const loc = locs.get(n);
    if (loc !== undefined) {
      out.set(n, loc);
      continue;
    }
    let best = es[0]!;
    for (const e of es) if (count[e]! < count[best]! - EPS) best = e;
    bump(best);
    out.set(n, best);
  }
  return out;
}

const isEdge = (e: PathEnd): e is { edge: number } => "edge" in e;
const rotateEnd = (e: PathEnd, r: number): PathEnd => (isEdge(e) ? { edge: mod6(e.edge + r) } : { node: e.node });

/**
 * Geometry of a tile (catalog entry or printed hex) at `rotation`: node positions
 * and one axis per path, in hex coordinates.
 */
export function tileGeometry(parts: TileParts, rotation: number, frame: HexFrame): TileGeometry {
  const r = mod6(rotation);
  const kinds = nodeKinds(parts);
  const paths = (parts.paths ?? []).map((p) => ({ a: rotateEnd(p.a, r), b: rotateEnd(p.b, r), terminal: !!p.terminal }));
  const off = NODE_OFFSET * frame.inradius;

  // exits per node (rotated edges of its edge paths)
  const exits = new Map<number, number[]>();
  for (const p of paths) {
    for (const [x, y] of [[p.a, p.b], [p.b, p.a]] as const) {
      if (!isEdge(x) && isEdge(y)) exits.set(x.node, [...(exits.get(x.node) ?? []), y.edge]);
    }
  }

  const nodes = new Map<number, NodeGeom>();
  let through: { node: number; curve: Curve; mid: Vec; edges: [number, number] } | null = null;
  const ids = [...kinds.keys()].sort((x, y) => x - y);

  // single plain town on a through track
  if (ids.length === 1) {
    const n = ids[0]!;
    const info = kinds.get(n)!;
    const es = exits.get(n) ?? [];
    const allEdgeToNode = paths.every((p) => isEdge(p.a) !== isEdge(p.b));
    if (info.kind === "town" && locNumber(info.loc) === null && paths.length === 2 && allEdgeToNode && es.length === 2 && es[0] !== es[1]) {
      const { curve } = edgeToEdge(frame, es[0]!, es[1]!);
      const mid = curvePoint(curve, 0.5);
      through = { node: n, curve, mid, edges: [es[0]!, es[1]!] };
      nodes.set(n, { node: n, kind: "town", pos: mid, placement: "throughTown" });
    }
  }

  const locs = new Map<number, number>();
  for (const n of ids) {
    const l = locNumber(kinds.get(n)!.loc);
    if (l !== null) locs.set(n, mod6(l + r));
  }
  let engine: Map<number, number> | null = null;
  const pathless: number[] = [];

  for (const n of ids) {
    if (nodes.has(n)) continue;
    const { kind } = kinds.get(n)!;
    const loc = locs.get(n);
    const put = (pos: Vec, placement: Placement): void => void nodes.set(n, { node: n, kind, pos, placement });
    if (loc !== undefined) {
      put(scale(edgePositionDirection(frame, loc), off), "loc");
    } else if (ids.length === 1) {
      put({ x: 0, y: 0 }, "center");
    } else if ((exits.get(n) ?? []).length > 0) {
      const es = exits.get(n)!;
      const centroid = scale(es.map((e) => edgeMidpoint(frame, e)).reduce(add), 1 / es.length);
      if (norm(centroid) > 0.05 * frame.inradius) {
        put(scale(unit(centroid), off), "exits");
      } else {
        engine ??= enginePreferredEdges(exits, locs);
        put(scale(frame.unit[engine.get(n)!]!, off), "engineEdge");
      }
    } else {
      pathless.push(n);
    }
  }
  if (pathless.length === 1 && ids.length === 2) {
    const n = pathless[0]!;
    const other = nodes.get(ids.find((m) => m !== n)!)!;
    const pos = norm(other.pos) > EPS ? scale(unit(other.pos), -off) : scale(frame.unit[mod6(r + 3)]!, off);
    nodes.set(n, { node: n, kind: kinds.get(n)!.kind, pos, placement: "pathless" });
  } else {
    pathless.forEach((n, i) => {
      const pos = scale(edgePositionDirection(frame, r + (i * 6) / pathless.length), off);
      nodes.set(n, { node: n, kind: kinds.get(n)!.kind, pos, placement: "pathless" });
    });
  }

  for (const d of parts.double_towns ?? []) {
    const g = nodes.get(d.node)!;
    const dir = scale(edgePositionDirection(frame, d.axis + r), DOUBLE_TOWN_MARK * frame.side);
    g.marks = [add(g.pos, dir), sub(g.pos, dir)];
    if (d.revenue_loc) g.revenueLoc = d.revenue_loc.map((l) => ((l + r) % 6 + 6) % 6);
  }

  const axes = paths.map((p, i): Axis => {
    let curve: Curve;
    let shape: AxisShape;
    if (isEdge(p.a) && isEdge(p.b)) {
      ({ curve, shape } = edgeToEdge(frame, p.a.edge, p.b.edge));
    } else if (!isEdge(p.a) && !isEdge(p.b)) {
      curve = { kind: "line", p0: nodes.get(p.a.node)!.pos, p1: nodes.get(p.b.node)!.pos };
      shape = "nodeToNode";
    } else {
      const edge = isEdge(p.a) ? p.a.edge : (p.b as { edge: number }).edge;
      const node = isEdge(p.a) ? (p.b as { node: number }).node : p.a.node;
      if (through && through.node === node) {
        // half of the through curve, oriented edge -> town
        curve = edge === through.edges[0] ? head(through.curve, 0.5) : head(reverse(through.curve), 0.5);
        shape = "throughTown";
      } else {
        curve = edgeToPoint(frame, edge, nodes.get(node)!.pos);
        shape = "toNode";
      }
      if (!isEdge(p.a)) curve = reverse(curve);
    }
    const length = curveLength(curve);
    if (!(length > EPS)) throw new Error(`path ${i} has no length`);
    return {
      path: i,
      a: p.a,
      b: p.b,
      terminal: p.terminal,
      shape,
      curve,
      start: curvePoint(curve, 0),
      end: curvePoint(curve, 1),
      startTangent: curveTangent(curve, 0),
      endTangent: curveTangent(curve, 1),
      length,
    };
  });

  return { nodes: ids.map((n) => nodes.get(n)!), axes };
}
