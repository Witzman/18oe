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

/**
 * Every slot within `reach` of the point (hex coordinates), nearest first. A slot counts when the point is
 * inside its circle (`r`) or within `reach`; with a finger the list can hold several (selection list, #259).
 */
export function slotsNear(slots: readonly Slot[], p: Vec, reach: number): Slot[] {
  return slots
    .map((s) => ({ s, d: Math.hypot(p.x - s.pos.x, p.y - s.pos.y) }))
    .filter((x) => x.d <= reach)
    .sort((a, b) => a.d - b.d)
    .map((x) => x.s);
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

/**
 * Arrow heads at the junction of a sea hex (#444): a port stub runs from a land side into the middle of the hex
 * and ends in an arrow. One triangle per stub, the tip at the junction, pointing along the stub, `length` long and
 * `width` wide across it. Nothing for a junction without a stub: a track junction on land branches paths that are
 * not terminal.
 */
export function junctionArrows(nodes: readonly NodeGeom[], axes: readonly Axis[], length: number, width: number): number[][] {
  const out: number[][] = [];
  for (const g of nodes) {
    if (g.kind !== "junction") continue;
    for (const a of axes) {
      const atEnd = "node" in a.b && a.b.node === g.node, atStart = "node" in a.a && a.a.node === g.node;
      if (!a.terminal || (!atEnd && !atStart)) continue;
      const t = atEnd ? a.endTangent : { x: -a.startTangent.x, y: -a.startTangent.y }; // pointing into the junction
      const n = norm(t);
      if (!(n > 0)) continue;
      const u = { x: t.x / n, y: t.y / n }, across = { x: -u.y, y: u.x };
      const bx = g.pos.x - u.x * length, by = g.pos.y - u.y * length;
      out.push([g.pos.x, g.pos.y, bx + across.x * width / 2, by + across.y * width / 2, bx - across.x * width / 2, by - across.y * width / 2]);
    }
  }
  return out;
}

/**
 * Colour of the home ring at the foot of a token (#448): light (map.city) on dark land, but on light land (the board
 * of map.jpg) a light ring would vanish, so the dark map.cityEdge is taken when the light one has too little contrast.
 */
export function homeRingColor(map: { city: number; cityEdge: number; land: number }, ratio: (a: number, b: number) => number, min = 1.5): number {
  return ratio(map.city, map.land) >= min ? map.city : map.cityEdge;
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

/** One line of a revenue box (#453): the value, and the train phase from which it applies where the board prints it. */
export interface RevenueRow { value: number; phase?: string }

/** Where the revenue box of a red hex sits (hex coordinates, side length 1), as map.jpg prints it. */
export interface RevenueBoxLayout {
  /** Centre, width and height of the white box. */
  box: { x: number; y: number; w: number; h: number };
  rowH: number;
  /** Centre of the first row; the others follow every rowH. */
  first: Vec;
  /** Centre of the name, below the box. */
  name: Vec;
  /** x of the phase numbers beside the box. */
  phaseX: number;
  /** Whether the phase numbers 3, 5, 7 fit beside the box (not on a red city, where the circles are next to it). */
  phases: boolean;
}

/**
 * The box of a true off-board sits a little left of the centre (the track ends under it); the box of a red city leaves
 * the middle to the city circles and sits at the upper left. The name goes below.
 */
export function revenueBoxLayout(rows: number, city: boolean): RevenueBoxLayout {
  const rowH = city ? 0.16 : 0.2;
  const w = city ? 0.36 : 0.5;
  const h = rows * rowH + 0.08;
  const cx = city ? -0.55 : -0.1, cy = city ? -0.3 : -0.08;
  return {
    box: { x: cx, y: cy, w, h }, rowH,
    first: { x: cx, y: cy - h / 2 + 0.04 + rowH / 2 },
    name: { x: city ? -0.1 : 0, y: city ? 0.56 : cy + h / 2 + 0.17 },
    phaseX: cx + w / 2 + 0.07,
    phases: !city,
  };
}

/** The phase numbers map.jpg prints beside the revenue of a red hex: green from phase 3, brown from 5, gray from 7. */
const PHASE_LABEL: Record<string, string> = { green: "3", brown: "5", gray: "7" };

/** The lines of a red hex's revenue box: one per tile colour in play order, or the single number. */
export function revenueRows(rev: Revenue | undefined): RevenueRow[] {
  if (rev === undefined) return [];
  if (typeof rev === "number") return [{ value: rev }];
  return PHASE_ORDER.filter((c) => c in rev).map((c) => ({ value: rev[c]!, phase: PHASE_LABEL[c] }));
}

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
