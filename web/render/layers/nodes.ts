// Cities, towns, off-boards and tokens (#147, ui-spec 2.3 layers 6 and 9, 2.5). The flat parts
// (medallions, town bars, off-board wedges, rings, patronage crests) go into the tile's container in
// the tiles layer, in flat hex coordinates like the track. Tokens are standing cylinders: drawn once in
// units of the side length (token.ts is pure maths, here only PixiJS) and placed in the objects layer
// by map.ts, which sets position and scale (= zoom) on every frame.
import { Container, Graphics } from "pixi.js";
import { citySlots, homeRingColor, junctionArrows, medallionExtent, offboardWedges, revenueBoxLayout, revenueRows, townBars, type Slot } from "../stones.ts";
import { contrast } from "../../themes/color.ts";
import { worldText } from "../world-text.ts";
import type { RenderTheme } from "../theme.ts";
import type { Axis, HexFrame, NodeGeom, Revenue, TileParts, Vec } from "../track-axes.ts";

/** Edge line of medallions and bars in side lengths. */
export const EDGE_LINE = 0.025;
/** Home ring at the foot of a token, and the reserved ring, as a factor of the token radius. */
export const RING_GAP = 1.28;

export type RingKind = "home" | "reserved";
export interface Ring { slot: Slot; kind: RingKind; color: number }

export interface NodesInput {
  parts: TileParts;
  nodes: readonly NodeGeom[];
  axes: readonly Axis[];
  frame: HexFrame;
  origin: Vec;
  /** Slots per city when more tokens are on the tile than its printed slots (never expected). */
  minSlots?: readonly number[];
  rings?: readonly Ring[];
  /** Cities that carry a patronage crest (city index). */
  patronage?: readonly number[];
  /** A red hex (#453): its name and revenue for the revenue box, and whether it is a red city (circles) or a true off-board. */
  redHex?: { name?: string; revenue?: Revenue; city: boolean };
}

const flat = (p: Vec, o: Vec): [number, number] => [o.x + p.x, o.y + p.y];

/** A dashed circle as short strokes. */
function dashedCircle(g: Graphics, cx: number, cy: number, r: number, dashes = 12): void {
  for (let i = 0; i < dashes; i++) {
    const a0 = (2 * Math.PI * i) / dashes, a1 = a0 + (Math.PI * 1.1) / dashes;
    g.moveTo(cx + r * Math.cos(a0), cy + r * Math.sin(a0)).arc(cx, cy, r, a0, a1);
  }
}

/** Small shield (crest) for a patronage city: pentagon pointing down. */
function crest(g: Graphics, x: number, y: number, s: number): void {
  g.poly([x - s, y - s, x + s, y - s, x + s, y + s * 0.3, x, y + s * 1.1, x - s, y + s * 0.3]);
}

/** Flat parts of one tile as one container. Medallion, bars and wedges use map.city / map.cityEdge. */
export function drawNodes(input: NodesInput, theme: RenderTheme): Container {
  const { parts, nodes, axes, frame, origin } = input;
  const r = theme.slotRadius;
  const node = new Container({ label: "nodes" });
  const g = new Graphics();
  // Off-board: the wedges to the map edge; one medallion-less mark when no track arrives.
  for (const n of theme.offboardBox > 0 ? [] : nodes.filter((x) => x.kind === "offboard")) {
    const wedges = offboardWedges(n, axes, frame);
    if (wedges.length === 0) {
      const [x, y] = flat(n.pos, origin);
      g.circle(x, y, r).fill({ color: theme.map.city }).stroke({ width: EDGE_LINE, color: theme.map.cityEdge });
    }
    for (const w of wedges) {
      g.poly(w.map((v, i) => v + (i % 2 === 0 ? origin.x : origin.y)), true)
        .fill({ color: theme.map.city }).stroke({ width: EDGE_LINE, color: theme.map.cityEdge, join: "round" });
    }
  }
  g.beginPath(); // a fill or stroke without a new shape would paint the last one again
  // Port stubs in sea hexes end in an arrow in the middle of the hex (#444).
  for (const arrow of junctionArrows(nodes, axes, theme.portArrowLength, theme.portArrowWidth)) {
    g.poly(arrow.map((v, i) => v + (i % 2 === 0 ? origin.x : origin.y)), true)
      .fill({ color: theme.map.ferry }).stroke({ width: EDGE_LINE, color: theme.map.cityEdge, join: "round" });
  }
  g.beginPath();
  // Towns: bars across the track.
  for (const bar of townBars(nodes, axes, theme.townLength, theme.townWidth)) {
    g.poly(bar.map((v, i) => v + (i % 2 === 0 ? origin.x : origin.y)), true).fill({ color: theme.map.cityEdge });
  }
  g.beginPath();
  // Cities: the plate is the union of the slot circles (edge first, then fill), the rings sit on top.
  const slots = citySlots(parts, nodes, r, input.minSlots);
  const plate = (extra: number, color: number) => {
    for (const s of slots) { const [x, y] = flat(s.pos, origin); g.circle(x, y, r + extra); }
    g.fill({ color });
  };
  if (slots.length) {
    plate(EDGE_LINE, theme.map.cityEdge);
    plate(0, theme.map.city);
  }
  for (const s of slots) {
    const [x, y] = flat(s.pos, origin);
    g.circle(x, y, r * 0.78).stroke({ width: EDGE_LINE * 0.7, color: theme.map.cityEdge });
  }
  node.addChild(g);
  // Rings: home (light, solid) and reserved (company colour, dashed).
  const rings = new Graphics();
  for (const ring of input.rings ?? []) {
    const [x, y] = flat(ring.slot.pos, origin);
    if (ring.kind === "home") rings.circle(x, y, theme.tokenRadius * RING_GAP).stroke({ width: EDGE_LINE * 1.4, color: homeRingColor(theme.map, (a, b) => contrast(hex(a), hex(b))) });
    else {
      dashedCircle(rings, x, y, r * 0.78);
      rings.stroke({ width: EDGE_LINE * 1.6, color: ring.color, cap: "round" });
    }
  }
  node.addChild(rings);
  // Patronage crest at the upper right of the medallion.
  const crests = new Graphics();
  for (const city of input.patronage ?? []) {
    const c = parts.cities?.[city];
    const n = c && nodes.find((x) => x.node === c.node);
    if (!c || !n) continue;
    const e = medallionExtent(c.slots ?? 1, r);
    const [x, y] = flat({ x: n.pos.x - e * 0.9, y: n.pos.y - e * 0.9 }, origin);
    crest(crests, x, y, r * 0.42);
  }
  crests.fill({ color: theme.map.selected }).stroke({ width: EDGE_LINE * 0.7, color: theme.map.cityEdge, join: "round" });
  node.addChild(crests);
  if (theme.offboardBox > 0 && input.redHex) node.addChild(drawRevenueBox(input.redHex, origin, theme));
  return node;
}

/**
 * The revenue box of a red hex as map.jpg prints it (#453): a white box with the value of every tile colour in a line,
 * the phase numbers 3, 5, 7 small beside it, the name below. Sizes in side lengths (hex coordinates + origin).
 */
export function drawRevenueBox(red: NonNullable<NodesInput["redHex"]>, origin: Vec, theme: RenderTheme): Container {
  const out = new Container({ label: "revenue-box" });
  const rows = revenueRows(red.revenue);
  if (rows.length === 0) return out;
  const L = revenueBoxLayout(rows.length, red.city);
  const g = new Graphics();
  g.rect(origin.x + L.box.x - L.box.w / 2, origin.y + L.box.y - L.box.h / 2, L.box.w, L.box.h)
    .fill({ color: theme.map.city }).stroke({ width: EDGE_LINE, color: theme.map.cityEdge });
  out.addChild(g);
  const size = red.city ? 0.14 : 0.18;
  rows.forEach((row, i) => {
    const y = origin.y + L.first.y + i * L.rowH;
    out.addChild(worldText(String(row.value), size, theme.map.label, theme, { x: origin.x + L.first.x, y }));
    if (row.phase && L.phases) out.addChild(worldText(row.phase, size * 0.75, theme.map.cityEdge, theme, { x: origin.x + L.phaseX, y }));
  });
  // the name gets a rim in the colour of the hex, so a track that runs under it does not cut it
  if (red.name) out.addChild(worldText(red.name, red.city ? 0.14 : 0.15, theme.map.label, theme, { x: origin.x + L.name.x, y: origin.y + L.name.y }, theme.map.tileRed));
  return out;
}

/** Ring marking the valid city targets (setTargets({ cities })), over the whole medallion. */
export function drawTargetCity(g: Graphics, slots: readonly Slot[], origin: Vec, theme: RenderTheme): void {
  for (const s of slots) {
    const [x, y] = flat(s.pos, origin);
    g.circle(x, y, theme.slotRadius * 1.15);
  }
  g.fill({ color: theme.map.valid, alpha: theme.targetAlpha }).stroke({ width: theme.focusLine * 0.6, color: theme.map.valid });
}

/** Mix colour a toward black by t (0..1). */
export function shade(color: number, t: number): number {
  const k = 1 - t;
  return (Math.round(((color >> 16) & 255) * k) << 16) | (Math.round(((color >> 8) & 255) * k) << 8) | Math.round((color & 255) * k);
}

/**
 * A standing token in units of the side length, origin at the foot centre: shadow, side wall,
 * foot and top ellipse, flattened by the pitch. Set `scale` to the zoom and `position` to the
 * projected foot.
 */
export function makeToken(theme: RenderTheme, color: number): Container {
  const r = theme.tokenRadius;
  const cp = Math.cos((theme.camera.pitch * Math.PI) / 180), sp = Math.sin((theme.camera.pitch * Math.PI) / 180);
  const h = theme.camera.heightToken * sp; // screen height of the cylinder, side lengths
  const ry = Math.max(r * cp, 0.012);
  const side = shade(color, 0.3);
  const az = (theme.camera.lightAzimuth * Math.PI) / 180;
  // Shadow falls away from the light: offset on the ground, flattened like the foot.
  const sx = -Math.cos(az) * theme.camera.heightToken * 0.9, sy = -Math.sin(az) * theme.camera.heightToken * 0.9 * cp;
  const shadow = new Graphics().ellipse(sx, sy, r * 1.05, Math.max(ry * 1.05, 0.012)).fill({ color: theme.map.shadow, alpha: Math.min(1, theme.camera.shadowAlpha * 2.4) });
  const body = new Graphics();
  body.ellipse(0, 0, r, ry).fill({ color: side });
  body.rect(-r, -h, 2 * r, h).fill({ color: side });
  body.ellipse(0, -h, r, ry).fill({ color }).stroke({ width: 0.012, color: shade(color, 0.45) });
  const out = new Container({ label: "token" });
  out.addChild(shadow, body);
  return out;
}

/**
 * A company token as 18xx.games draws it (#618): a flat disc filling the station slot, in units of the side length,
 * origin at its centre. The abbreviation is drawn on top by the map. Set `scale` and `position` as for makeToken.
 */
export function makeBadge(theme: RenderTheme, color: number): Container {
  const r = theme.slotRadius * BADGE_FILL;
  const ry = Math.max(r * Math.cos((theme.camera.pitch * Math.PI) / 180), 0.012);
  const out = new Container({ label: "token" });
  out.addChild(new Graphics().ellipse(0, 0, r, ry).fill({ color }).stroke({ width: 0.012, color: shade(color, 0.45) }));
  return out;
}

/** Radius of a badge as a share of the station slot radius. */
export const BADGE_FILL = 0.96;

const hex = (n: number): string => `#${n.toString(16).padStart(6, "0")}`;

/** Text colour on a company-coloured token top: the best-contrasting of the theme inks, black and white (computed, ui-spec 1.3). */
export function inkOn(bg: number, theme: RenderTheme): number {
  let best = theme.ui.ink, bestRatio = -1;
  for (const c of [theme.ui.ink, theme.ui.panel, 0x000000, 0xffffff]) {
    const r = contrast(hex(c), hex(bg));
    if (r > bestRatio + 1e-9) { best = c; bestRatio = r; }
  }
  return best;
}
