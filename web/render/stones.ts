// Cities, towns, off-boards and tokens as game pieces (#147, ui-spec 2.5). Pure geometry in hex
// coordinates (origin = hex centre, side length 1, y down), no PixiJS, checked under `node --test`.
// The drawing is layers/nodes.ts; map.ts places the standing tokens.
//
// ASSUMPTIONS (the spec leaves them open, nothing is checked against the physical tiles):
// - Slot layout by slot count: 1 centre, 2 a horizontal pill (two circles side by side), 3 a triangle
//   (apex up), 4 a square, more a ring. Neighbouring slots overlap by SLOT_OVERLAP so the medallion
//   reads as one plate with distinct rings.
// - A town bar stands across the track at the node (perpendicular to the first axis ending there).
// - Revenue shields sit up and to the right of the node, double-town shields on `revenue_loc`.
import { edgePositionDirection, norm, type Axis, type HexFrame, type NodeGeom, type Revenue, type TileParts, type Vec } from "./track-axes.ts";

/** Centre distance of neighbouring slots in slot radii (< 2 = the circles overlap a little). */
export const SLOT_OVERLAP = 1.9;

/** Offsets of the slot centres from the node for `n` slots of radius r. */
export function slotOffsets(n: number, r: number): Vec[] {
  if (n <= 0) return [];
  if (n === 1) return [{ x: 0, y: 0 }];
  const d = SLOT_OVERLAP * r;
  if (n === 2) return [{ x: -d / 2, y: 0 }, { x: d / 2, y: 0 }];
  if (n === 4) return [{ x: -d / 2, y: -d / 2 }, { x: d / 2, y: -d / 2 }, { x: -d / 2, y: d / 2 }, { x: d / 2, y: d / 2 }];
  // Regular polygon with side d, first vertex up (3: triangle with the apex up).
  const R = d / (2 * Math.sin(Math.PI / n));
  return Array.from({ length: n }, (_, i) => {
    const a = -Math.PI / 2 + (2 * Math.PI * i) / n;
    return { x: R * Math.cos(a), y: R * Math.sin(a) };
  });
}

/** Radius of the circle around the node that holds the whole medallion. */
export function medallionExtent(n: number, r: number): number {
  return slotOffsets(n, r).reduce((m, p) => Math.max(m, norm(p)), 0) + r;
}

export interface Slot {
  /** Engine city index on the tile (index in `parts.cities`) and slot index in that city. */
  city: number;
  slot: number;
  /** Centre in hex coordinates. */
  pos: Vec;
}

/** Slot centres of every city of a tile; `slots` falls back to 1. */
export function citySlots(parts: TileParts, nodes: readonly NodeGeom[], r: number, minSlots: readonly number[] = []): Slot[] {
  const out: Slot[] = [];
  (parts.cities ?? []).forEach((c, city) => {
    const g = nodes.find((n) => n.node === c.node);
    if (!g) return;
    const n = Math.max(c.slots ?? 1, minSlots[city] ?? 0);
    slotOffsets(n, r).forEach((o, slot) => out.push({ city, slot, pos: { x: g.pos.x + o.x, y: g.pos.y + o.y } }));
  });
  return out;
}

/**
 * The slot hit by a point (hex coordinates), else null. The hit area of a slot is its circle, at
 * least `minHit` wide (a finger is bigger than a small token); the nearest centre wins.
 */
export function hitSlot(slots: readonly Slot[], p: Vec, r: number, minHit = 0): Slot | null {
  const reach = Math.max(r, minHit);
  let best: Slot | null = null;
  let bestD = Infinity;
  for (const s of slots) {
    const d = Math.hypot(p.x - s.pos.x, p.y - s.pos.y);
    if (d <= reach && d < bestD) { best = s; bestD = d; }
  }
  return best;
}

/** Four corners (flat x, y) of a bar across `tangent` at `pos`. */
export function townBar(pos: Vec, tangent: Vec | null, length: number, width: number): number[] {
  const t = tangent && norm(tangent) > 0 ? { x: tangent.x / norm(tangent), y: tangent.y / norm(tangent) } : { x: 1, y: 0 };
  const n = { x: -t.y, y: t.x }; // across the track
  const hl = length / 2, hw = width / 2;
  const c = (a: number, b: number): [number, number] => [pos.x + n.x * a * hl + t.x * b * hw, pos.y + n.y * a * hl + t.y * b * hw];
  return [...c(-1, -1), ...c(1, -1), ...c(1, 1), ...c(-1, 1)];
}

/** Unit tangent of the first axis that ends at `node`, pointing along the track through it. */
export function trackAt(axes: readonly Axis[], node: number): Vec | null {
  for (const a of axes) {
    if ("node" in a.a && a.a.node === node) return a.startTangent;
    if ("node" in a.b && a.b.node === node) return a.endTangent;
  }
  return null;
}

/** Town bars of a tile: one per town, two per double town, none for the rest. */
export function townBars(nodes: readonly NodeGeom[], axes: readonly Axis[], length: number, width: number): number[][] {
  const out: number[][] = [];
  for (const g of nodes) {
    if (g.kind === "town") out.push(townBar(g.pos, trackAt(axes, g.node), length, width));
    else if (g.kind === "double_town" && g.marks) {
      const dir = { x: g.marks[1].x - g.marks[0].x, y: g.marks[1].y - g.marks[0].y };
      for (const m of g.marks) out.push(townBar(m, dir, length, width));
    }
  }
  return out;
}

/** Off-board wedges: the tip at the node, the base across the hex edge the track enters through. */
export function offboardWedges(node: NodeGeom, axes: readonly Axis[], frame: HexFrame, halfBase = 0.22): number[][] {
  const out: number[][] = [];
  for (const a of axes) {
    const edgeEnd = "edge" in a.a && "node" in a.b && a.b.node === node.node ? a.a : "edge" in a.b && "node" in a.a && a.a.node === node.node ? a.b : null;
    if (!edgeEnd || !("edge" in edgeEnd)) continue;
    const u = frame.unit[((edgeEnd.edge % 6) + 6) % 6]!;
    const m = { x: u.x * frame.inradius, y: u.y * frame.inradius };
    const across = { x: -u.y, y: u.x };
    out.push([node.pos.x, node.pos.y, m.x + across.x * halfBase, m.y + across.y * halfBase, m.x - across.x * halfBase, m.y - across.y * halfBase]);
  }
  return out;
}

const PHASE_ORDER = ["yellow", "green", "brown", "gray"];

/** The revenue a node shows: a plain number, or the value of the newest tile colour in play. */
export function revenueNow(rev: Revenue | undefined, colors: readonly string[]): number | null {
  if (rev === undefined) return null;
  if (typeof rev === "number") return rev;
  const open = PHASE_ORDER.filter((c) => colors.includes(c) && c in rev);
  if (open.length) return rev[open[open.length - 1]!]!;
  const any = PHASE_ORDER.filter((c) => c in rev);
  return any.length ? rev[any[0]!]! : null;
}

/** Off-board text: all phase values in colour order ("30/50/80/100"), or the single number. */
export function revenueAll(rev: Revenue | undefined): string | null {
  if (rev === undefined) return null;
  if (typeof rev === "number") return String(rev);
  const vals = PHASE_ORDER.filter((c) => c in rev).map((c) => rev[c]!);
  return vals.length ? vals.join("/") : null;
}

/** Where a node's revenue shield sits (hex coordinates). */
export function shieldAt(g: NodeGeom, extent: number, frame: HexFrame): Vec {
  if (g.kind === "double_town" && g.revenueLoc?.length) {
    const d = edgePositionDirection(frame, g.revenueLoc[0]!);
    return { x: d.x * frame.inradius * 0.55, y: d.y * frame.inradius * 0.55 };
  }
  return { x: g.pos.x + extent * 0.95, y: g.pos.y - extent * 0.95 };
}

/** Corner of the hex where the tile label sits (upper left, hex coordinates). */
export function labelAt(frame: HexFrame): Vec {
  return { x: -frame.side * 0.55, y: -frame.inradius * 0.75 };
}

/** Colour slot of a corporation: a stable index into the placeholder company colours (assumption until #99). */
export function companyIndex(corporations: readonly { id: string }[], id: string, count: number): number {
  const i = corporations.findIndex((c) => c.id === id);
  return (i < 0 ? 0 : i) % count;
}
