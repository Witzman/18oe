// Static layers (ui-spec 2.3, layers 1, 3, 5): sea and land plates, hex lines, province borders,
// terrain signs. Drawn per block of 8 x 8 hexes in flat world coordinates; the level container
// above carries the camera matrix. Redrawn only on a theme change.
import { Container, FillGradient, Graphics } from "pixi.js";
import { blob, landRings, landShapes } from "../coast.ts";
import { worldCorners, type Vec, type View } from "../projection.ts";
import {
  BLOCK, blockKey, GLYPH_AT, gridEdges, terrainGlyph, terrainMark, terrainShape, topColor, zoneSegments,
  mix, wallFaces, type Plate, type Scene,
} from "../scene.ts";
import type { RenderTheme } from "../theme.ts";
import type { Box } from "../projection.ts";
import { dashes, seaOfHex, zoneBorders, zoneMarks } from "../sea-zones.ts";
import { worldText } from "../world-text.ts";

export interface Block {
  /** Index into Scene.levels. */
  level: number;
  box: Box;
  node: Container;
  /** Parts shown only from zoom stage Z1 (hex lines, terrain signs). */
  detail?: Container;
}

const flat = (ps: Vec[]) => ps.flatMap((p) => [p.x, p.y]);

/** A plate: the tops of the hexes of one block on one level (the walls between levels are drawWalls). */
export function drawPlate(scene: Scene, plate: Plate, theme: RenderTheme): Block {
  const g = new Graphics();
  for (const h of plate.hexes) {
    const hex = scene.hexById.get(h.id)!;
    g.poly(flat(worldCorners(scene.grid, h))).fill({ color: topColor(hex, h, theme.map, scene.bounds) });
  }
  return { level: plate.level, box: plate.box, node: g };
}

/**
 * Wall layer (#145): one Graphics per height level with the front faces of the hexes of that level,
 * back to front, in screen units of `unit` (the view with zoom 1 and pan 0). The level container
 * carries position = pan and scale = zoom, so the faces are redrawn only when pitch, yaw or the
 * theme change, not when the camera pans or zooms. Empty at pitch 0.
 */
export function drawWalls(scene: Scene, unit: View, theme: RenderTheme): Graphics[] {
  const out = scene.levels.map(() => new Graphics());
  for (const f of wallFaces(scene, unit, theme)) {
    // A hairline in the face colour closes the seams between neighbouring faces under anti-aliasing.
    out[f.level]!.poly(flat(f.polygon)).fill({ color: f.color }).stroke({ width: 0.012, color: f.color, join: "round" });
  }
  return out;
}

/**
 * Grid blocks: per level and block the hex lines (1 px, map.hexLine at shape.hexLineAlpha) and
 * terrain signs of the hexes whose top is on that level, plus the province borders drawn there.
 */
export function drawGrid(scene: Scene, theme: RenderTheme): Block[] {
  const flat = theme.camera.pitch === 0;
  const zones = new Map<string, { a: Vec; b: Vec }[]>();
  for (const s of zoneSegments(scene)) {
    const list = zones.get(s.hex);
    if (list) list.push(s);
    else zones.set(s.hex, [s]);
  }
  const groups = new Map<string, { level: number; ids: string[] }>();
  for (const h of scene.grid.hexes) {
    const level = scene.levelOf.get(h.id)!;
    const k = `${level}/${blockKey(h)}`;
    const g = groups.get(k);
    if (g) g.ids.push(h.id);
    else groups.set(k, { level, ids: [h.id] });
  }
  const out: Block[] = [];
  for (const { level, ids } of groups.values()) {
    const node = new Container();
    const detail = new Graphics();
    const signs = new Container(); // terrain signs with the cost in them (#450)
    const zone = new Graphics();
    const seaLines: [Vec, Vec][] = []; // hex sides between two sea hexes (#449: their own alpha, none on the board)
    const box = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
    let zoneLines = 0;
    for (const id of ids) {
      const h = scene.grid.byId.get(id)!;
      const corners = worldCorners(scene.grid, h);
      for (const p of corners) {
        box.minX = Math.min(box.minX, p.x); box.maxX = Math.max(box.maxX, p.x);
        box.minY = Math.min(box.minY, p.y); box.maxY = Math.max(box.maxY, p.y);
      }
      for (const i of gridEdges(scene, h)) {
        // Flat map (#100): the soft coast replaces the hex edges between land and sea.
        if (flat) {
          const nid = h.neighbors[i], n = nid ? scene.grid.byId.get(nid) : undefined;
          if (n && (n.z > 0) !== (h.z > 0)) continue;
          if (h.z === 0 && (!n || n.z === 0)) { // between two sea hexes, or on the edge of the map
            if (theme.seaHexLineAlpha > 0) seaLines.push([corners[(i + 5) % 6]!, corners[i]!]);
            continue;
          }
        }
        const a = corners[(i + 5) % 6]!, b = corners[i]!;
        detail.moveTo(a.x, a.y).lineTo(b.x, b.y);
      }
      for (const s of zones.get(id) ?? []) {
        zone.moveTo(s.a.x, s.a.y).lineTo(s.b.x, s.b.y);
        zoneLines++;
      }
    }
    detail.stroke({ width: 1, pixelLine: true, color: theme.map.hexLine, alpha: theme.hexLineAlpha });
    if (seaLines.length) {
      for (const [a, b] of seaLines) detail.moveTo(a.x, a.y).lineTo(b.x, b.y);
      detail.stroke({ width: 1, pixelLine: true, color: theme.map.hexLine, alpha: theme.hexLineAlpha * theme.seaHexLineAlpha });
    }
    for (const id of ids) {
      const mark = terrainMark(scene.hexById.get(id)!);
      if (!mark) continue;
      const h = scene.grid.byId.get(id)!;
      if (theme.terrainSymbols > 0) { drawSign(signs, mark, h, theme); continue; }
      for (const line of terrainGlyph(mark.kind)) {
        line.forEach((p, i) => {
          const x = h.x + GLYPH_AT.x + p.x, y = h.y + GLYPH_AT.y + p.y;
          if (i === 0) detail.moveTo(x, y);
          else detail.lineTo(x, y);
        });
      }
    }
    detail.stroke({ width: theme.zoneLine, color: theme.map.label, cap: "round", join: "round" });
    if (zoneLines) zone.stroke({ width: theme.zoneLine, color: theme.map.zoneBorder, cap: "round" });
    const group = new Container();
    group.addChild(detail, signs);
    node.addChild(group, zone);
    out.push({ level, box, node, detail: group });
  }
  return out;
}

export { BLOCK };

/** Soft layers of a terrain blob, outer to inner: hex scale and alpha (assumption, see #100). */
export const BLOB_LAYERS = [{ scale: 0.95, alpha: 0.35 }, { scale: 0.62, alpha: 0.5 }] as const;
/** Chaikin cut ratio of terrain blobs. */
const BLOB_ROUND = 0.3;

export interface Coast {
  /** The sea: one rectangle over the map box with the seaDeep to seaShallow gradient (NW to SE). */
  sea: Graphics;
  /** Shore halo and land mass in map.land, with the soft terrain on top. */
  land: Graphics;
}

/**
 * Flat map (camera.pitch 0, #100): the sea as one gradient surface and the land as one smoothed
 * surface (union of the land hexes, landRings), so the board does not read as a honeycomb. Hills,
 * mountains and water terrain are soft blobs on the land. Static; redrawn only on a theme change.
 */
export function drawCoast(scene: Scene, theme: RenderTheme): Coast {
  const { map } = theme;
  const b = scene.bounds;
  const sea = new Graphics();
  const tinted = theme.seaTint > 0 && !!scene.geometry.sea_zones?.length;
  if (tinted) drawTintedSea(sea, scene, theme);
  else {
    const grad = new FillGradient({
      type: "linear", start: { x: 0, y: 0 }, end: { x: 1, y: 1 }, textureSpace: "local",
      colorStops: [{ offset: 0, color: map.seaDeep }, { offset: 1, color: map.seaShallow }],
    });
    sea.rect(b.minX, b.minY, b.maxX - b.minX, b.maxY - b.minY).fill(grad);
  }
  drawSeaZones(sea, scene, theme);

  const land = new Graphics();
  const rings = landRings(scene, { round: theme.coastRound, noise: theme.coastNoise });
  // Shallow water along the shore (under the land), then the land, then a thin shore line.
  const halo = mix(map.seaShallow, 0xffffff, 0.35);
  for (const r of rings) land.poly(flat(r.points), true).stroke({ width: 0.4, color: halo, alpha: 0.3, join: "round" });
  const shapes = landShapes(rings);
  for (const { outer, holes } of shapes) {
    land.poly(flat(outer.points), true).fill({ color: map.land });
    for (const h of holes) land.poly(flat(h.points), true).cut();
  }
  for (const r of rings) land.poly(flat(r.points), true).stroke({ width: 0.035, color: map.landLow, alpha: 0.8, join: "round" });
  // Soft terrain: the strongest type of a hex decides the colour (terrainMark).
  const colorOf = { hill: map.landHigh, mountain: map.mountain, water: map.water } as const;
  for (const kind of theme.terrainBlobAlpha > 0 ? (["water", "hill", "mountain"] as const) : []) {
    for (const hex of scene.geometry.hexes) {
      if ((scene.levelOf.get(hex.id) ?? 0) === 0 || terrainMark(hex)?.kind !== kind) continue;
      for (const l of BLOB_LAYERS) land.poly(flat(blob(scene, hex.id, l.scale, BLOB_ROUND, 1)), true).fill({ color: colorOf[kind], alpha: l.alpha * theme.terrainBlobAlpha });
    }
  }
  return { sea, land };
}

/** The sea as one surface (#449): the north seas in map.seaNorth over the whole map, the Mediterranean and the Black Sea in map.seaMed on top. */
function drawTintedSea(sea: Graphics, scene: Scene, theme: RenderTheme): void {
  const { map } = theme;
  const b = scene.bounds;
  sea.rect(b.minX, b.minY, b.maxX - b.minX, b.maxY - b.minY).fill({ color: map.seaNorth });
  const seas = seaOfHex(scene.geometry.sea_zones);
  for (const [id, group] of seas) {
    if (group !== "mediterranean") continue;
    const h = scene.grid.byId.get(id);
    if (!h) continue;
    // a hairline in the same colour closes the seams between hexes under anti-aliasing
    sea.poly(flat(worldCorners(scene.grid, h))).fill({ color: map.seaMed }).stroke({ width: 0.03, color: map.seaMed, join: "round" });
  }
}

/** Sea zone boundaries as white dashes, and a circle with the city limit "-1" in every zone (#449). */
function drawSeaZones(sea: Graphics, scene: Scene, theme: RenderTheme): void {
  const { map } = theme;
  const hexes = scene.geometry.hexes;
  for (const border of zoneBorders(hexes)) {
    const h = scene.grid.byId.get(border.hex);
    if (!h) continue;
    const corners = worldCorners(scene.grid, h);
    for (const [a, c] of dashes(corners[(border.edge + 5) % 6]!, corners[border.edge]!, theme.seaZoneDash, theme.seaZoneGap)) sea.moveTo(a.x, a.y).lineTo(c.x, c.y);
  }
  sea.stroke({ width: theme.seaZoneWidth, color: map.seaZoneLine, cap: "butt" });
  const seas = seaOfHex(scene.geometry.sea_zones);
  const r = theme.seaMarkRadius;
  for (const m of zoneMarks(hexes)) {
    const color = seas.get(m.hex) === "mediterranean" ? map.seaMarkMed : map.seaMarkNorth;
    sea.circle(m.x, m.y, r).fill({ color }).stroke({ width: r * 0.1, color: map.seaZoneLine });
    // "-1": a minus and a one, in strokes (the circle scales with the map like a printed mark)
    const w = r * 0.14;
    sea.moveTo(m.x - r * 0.62, m.y + r * 0.02).lineTo(m.x - r * 0.18, m.y + r * 0.02);
    sea.moveTo(m.x + r * 0.3, m.y - r * 0.42).lineTo(m.x + r * 0.3, m.y + r * 0.42).moveTo(m.x + r * 0.3, m.y - r * 0.42).lineTo(m.x + r * 0.1, m.y - r * 0.26);
    sea.stroke({ width: w, color: map.seaZoneLine, cap: "round", join: "round" });
  }
}

/** A terrain sign of the board (#450): a filled shape in the colour of its kind, darker the dearer it is, with the cost in it. */
function drawSign(into: Container, mark: { kind: "mountain" | "hill" | "water"; cost: number }, h: { x: number; y: number }, theme: RenderTheme): void {
  const shape = terrainShape(mark.kind, mark.cost);
  const base = theme.map[mark.kind];
  const fill = shape.depth >= 1 ? mix(base, 0x000000, 0.2) : mix(base, 0xffffff, 0.35 * (1 - shape.depth));
  const g = new Graphics();
  g.poly(flat(shape.polygon.map((p) => ({ x: h.x + p.x, y: h.y + p.y }))), true)
    .fill({ color: fill }).stroke({ width: 0.025, color: mix(fill, 0x000000, 0.5), join: "round" });
  into.addChild(g);
  into.addChild(worldText(String(mark.cost), shape.size, theme.map.label, theme, { x: h.x + shape.number.x, y: h.y + shape.number.y }));
}
