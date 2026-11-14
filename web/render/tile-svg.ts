// A tile as a small SVG picture (#48): the choice of tiles in the track panel shows the tile as it would lie,
// with the same track axes as the map (track-axes.ts) and the same edge directions (/map `edge_vectors`).
// Pure functions returning kit VNodes, so `node --test` checks the picture without a browser.
// Colours come from the theme's CSS variables (--map-tile-yellow, --map-track, --map-city, ...), so both
// themes and later palette changes reach the picture without code changes.
import { v, type VNode } from "../ui/kit/vnode.ts";
import { tileGeometry, type Curve, type HexFrame, type TileParts, type Vec } from "./track-axes.ts";

const r2 = (n: number) => Math.round(n * 1000) / 1000;
const pt = (p: Vec) => `${r2(p.x)} ${r2(p.y)}`;

/** SVG path data of one axis curve (hex coordinates, y down like SVG). */
export function curvePath(c: Curve): string {
  if (c.kind === "line") return `M ${pt(c.p0)} L ${pt(c.p1)}`;
  if (c.kind === "bezier") return `M ${pt(c.p0)} Q ${pt(c.c)} ${pt(c.p1)}`;
  const at = (a: number): Vec => ({ x: c.center.x + c.radius * Math.cos(a), y: c.center.y + c.radius * Math.sin(a) });
  const large = Math.abs(c.sweep) > Math.PI ? 1 : 0;
  // A positive sweep turns from +x towards +y, which is clockwise on screen = SVG sweep flag 1.
  return `M ${pt(at(c.start))} A ${r2(c.radius)} ${r2(c.radius)} 0 ${large} ${c.sweep > 0 ? 1 : 0} ${pt(at(c.start + c.sweep))}`;
}

/** The six corners of the hex: between two neighbouring edge directions, at the side length. */
export function hexCorners(frame: HexFrame): Vec[] {
  return frame.unit.map((u, i) => {
    const w = frame.unit[(i + 1) % 6]!;
    const m = { x: u.x + w.x, y: u.y + w.y };
    const n = Math.hypot(m.x, m.y);
    return { x: (m.x / n) * frame.side, y: (m.y / n) * frame.side };
  });
}

const COLORS = new Set(["yellow", "green", "brown", "gray", "red"]);

/** CSS colour of a tile colour name, from the theme variables; unknown colours fall back to yellow. */
export const tileFill = (color: string | undefined) => `var(--map-tile-${COLORS.has(color ?? "") ? color : "yellow"})`;

export interface TileSvgOptions {
  /** Engine tile colour (yellow, green, ...). */
  color?: string;
  /** Accessible name of the picture. */
  label?: string;
  /** Width and height in px (the viewBox is fitted to the hex). */
  size?: number;
}

/** The tile `parts` in `rotation` as an SVG: hex in the tile colour, track axes, cities (slot circles) and towns. */
export function tileSvg(parts: TileParts, rotation: number, frame: HexFrame, opts: TileSvgOptions = {}): VNode {
  const geom = tileGeometry(parts, rotation, frame);
  const s = frame.side;
  const pad = s * 0.08;
  const size = opts.size ?? 56;
  const corners = hexCorners(frame);
  const width = s * 0.16;
  const tracks = geom.axes.map((a) => v("path", { d: curvePath(a.curve), fill: "none", stroke: "var(--map-track)", "stroke-width": String(r2(width)), "stroke-linecap": "butt" }));
  const nodes = geom.nodes.flatMap((n): VNode[] => {
    if (n.kind === "city") {
      const slots = parts.cities?.find((c) => c.node === n.node)?.slots ?? 1;
      const r = s * 0.2;
      // Slots side by side along x (as on the physical tile), centred on the node.
      return Array.from({ length: slots }, (_, i) => v("circle", {
        cx: String(r2(n.pos.x + (i - (slots - 1) / 2) * 2 * r)), cy: String(r2(n.pos.y)), r: String(r2(r)),
        fill: "var(--map-city)", stroke: "var(--map-city-edge)", "stroke-width": String(r2(s * 0.04)),
      }));
    }
    if (n.kind === "town" || n.kind === "junction") return n.kind === "town" ? [v("circle", { cx: String(r2(n.pos.x)), cy: String(r2(n.pos.y)), r: String(r2(s * 0.1)), fill: "var(--map-track)" })] : [];
    if (n.kind === "double_town") return (n.marks ?? [n.pos, n.pos]).map((m) => v("circle", { cx: String(r2(m.x)), cy: String(r2(m.y)), r: String(r2(s * 0.09)), fill: "var(--map-track)" }));
    return [];
  });
  const view = `${r2(-s - pad)} ${r2(-s - pad)} ${r2(2 * (s + pad))} ${r2(2 * (s + pad))}`;
  return v("svg", { class: "tile-svg", viewBox: view, width: String(size), height: String(size), role: "img", "aria-label": opts.label ?? "" },
    v("polygon", { points: corners.map(pt).join(" "), fill: tileFill(opts.color), stroke: "var(--map-tile-edge)", "stroke-width": String(r2(s * 0.03)) }),
    ...tracks, ...nodes);
}
