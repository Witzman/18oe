// Track picture (#146, ui-spec 2.6): the axes of a tile (track-axes.ts, #144) drawn as a bed (band of
// bedWidth), sleepers (rectangles across the tangent every sleeperSpacing) and two rails (parallel
// curves at +-gauge/2). Neutral: the colour of a track never depends on who laid it (owner decision
// on #146, 2026-11-12: track is shared infrastructure; company colour sits on tokens, trains, runs
// and seals). So `track.colorMode` / `colorPart` are read but all values draw map.bed / sleeper / rail.
//
// `trackPicture` is pure geometry in hex coordinates plus an origin (no PixiJS), checked under
// `node --test`; `drawTrack` turns it into Graphics. Where two paths cross in a hex without a node
// the beds lie on top of each other, then all sleepers, then all rails (every rail is drawn).
import { Container, Graphics } from "pixi.js";
import { polyline, samplesEvery, pointAt } from "./axis-sample.ts";
import type { ZoomStage } from "./camera.ts";
import type { RenderTheme } from "./theme.ts";
import type { Axis, Vec } from "./track-axes.ts";

/** A terminal track tapers over its last 30 % towards the node (ui-spec 2.6). */
export const TAPER = 0.3;
/** Width factor at the tip of a tapered track. */
export const TAPER_TIP = 0.15;
/** Maximum distance of polyline points (ui-spec 2.6). */
const MAX_STEP = 0.05;

type TrackDims = Pick<RenderTheme["track"], "gauge" | "railWidth" | "sleeperSpacing" | "sleeperLength" | "sleeperWidth" | "bedWidth">;

export interface TrackPicture {
  /** Closed polygons (flat x, y pairs) of the bed, one per axis. */
  beds: number[][];
  /** Closed quads of the sleepers. */
  sleepers: number[][];
  /** Open polylines (flat) of the rails, two per axis. */
  rails: number[][];
  /** Centre lines (flat), one per axis, for the simplest zoom stage. */
  lines: number[][];
}

const isNode = (e: Axis["a"]): boolean => "node" in e;

/** Width factor 0..1 at distance s from the axis start: 1, or tapering towards the node end of a terminal axis. */
export function widthFactor(axis: Axis, s: number): number {
  if (!axis.terminal) return 1;
  const tipAtEnd = isNode(axis.b) || !isNode(axis.a);
  const d = (tipAtEnd ? axis.length - s : s) / axis.length; // 0 at the tip
  if (d >= TAPER) return 1;
  return TAPER_TIP + (1 - TAPER_TIP) * Math.max(0, d / TAPER);
}

const flat = (pts: Vec[]): number[] => pts.flatMap((p) => [p.x, p.y]);

/** Offset curve of the axis by `side * halfWidth(s)` along the left normal. */
function offsetLine(axis: Axis, origin: Vec, half: (s: number) => number, side: 1 | -1): Vec[] {
  return polyline(axis, MAX_STEP, origin).map((p) => {
    const h = side * half(p.s);
    return { x: p.x - p.ty * h, y: p.y + p.tx * h };
  });
}

export function trackPicture(axes: readonly Axis[], origin: Vec, dims: TrackDims): TrackPicture {
  const out: TrackPicture = { beds: [], sleepers: [], rails: [], lines: [] };
  for (const axis of axes) {
    if (!(axis.length > 0)) continue;
    const f = (s: number) => widthFactor(axis, s);
    out.lines.push(flat(polyline(axis, MAX_STEP, origin)));
    const left = offsetLine(axis, origin, (s) => (dims.bedWidth / 2) * f(s), 1);
    const right = offsetLine(axis, origin, (s) => (dims.bedWidth / 2) * f(s), -1);
    out.beds.push(flat([...left, ...right.reverse()]));
    for (const p of samplesEvery(axis, dims.sleeperSpacing, undefined, origin)) {
      const hl = (dims.sleeperLength / 2) * f(p.s), hw = dims.sleeperWidth / 2;
      const nx = -p.ty, ny = p.tx; // left normal
      const c = (a: number, b: number): [number, number] => [p.x + nx * a * hl + p.tx * b * hw, p.y + ny * a * hl + p.ty * b * hw];
      out.sleepers.push([...c(-1, -1), ...c(1, -1), ...c(1, 1), ...c(-1, 1)]);
    }
    for (const side of [1, -1] as const) out.rails.push(flat(offsetLine(axis, origin, (s) => (dims.gauge / 2) * f(s), side)));
  }
  return out;
}

/** Position of the axis ends in world coordinates (tests: bed ends sit on the edge midpoints). */
export function axisEnds(axis: Axis, origin: Vec): [Vec, Vec] {
  const a = pointAt(axis, 0, origin), b = pointAt(axis, axis.length, origin);
  return [{ x: a.x, y: a.y }, { x: b.x, y: b.y }];
}

/** Containers of one tile's track, one Graphics per part so the zoom stage only toggles visibility. */
export interface TrackNode {
  node: Container;
  line: Graphics;
  bed: Graphics;
  sleepers: Graphics;
  rails: Graphics;
}

/**
 * Zoom stages (ui-spec 2.8): Z0 one line per axis, Z1 bed and rails, Z2 bed, sleepers and rails.
 * (Z0 line width: the outer rail edges, so the picture does not thin out when sleepers drop away.)
 */
export function trackVisibility(stage: ZoomStage): { line: boolean; bed: boolean; sleepers: boolean; rails: boolean } {
  return { line: stage === 0, bed: stage >= 1, sleepers: stage >= 2, rails: stage >= 1 };
}

export function setTrackStage(t: TrackNode, stage: ZoomStage): void {
  const v = trackVisibility(stage);
  t.line.visible = v.line;
  t.bed.visible = v.bed;
  t.sleepers.visible = v.sleepers;
  t.rails.visible = v.rails;
}

export function drawTrack(axes: readonly Axis[], origin: Vec, theme: RenderTheme): TrackNode {
  const t = theme.track;
  const pic = trackPicture(axes, origin, t);
  const node = new Container({ label: "track" });
  const line = new Graphics(), bed = new Graphics(), sleepers = new Graphics(), rails = new Graphics();
  for (const l of pic.lines) line.poly(l, false);
  line.stroke({ width: t.gauge + 2 * t.railWidth, color: theme.map.rail, join: "round", cap: "butt" });
  for (const p of pic.beds) bed.poly(p, true);
  bed.fill({ color: theme.map.bed });
  for (const q of pic.sleepers) sleepers.poly(q, true);
  sleepers.fill({ color: theme.map.sleeper });
  for (const r of pic.rails) rails.poly(r, false);
  rails.stroke({ width: t.railWidth, color: theme.map.rail, join: "round", cap: "butt" });
  node.addChild(line, bed, sleepers, rails);
  return { node, line, bed, sleepers, rails };
}
