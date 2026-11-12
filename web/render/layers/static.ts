// Static layers (ui-spec 2.3, layers 1, 3, 5): sea and land plates, hex lines, province borders,
// terrain signs. Drawn per block of 8 x 8 hexes in flat world coordinates; the level container
// above carries the camera matrix. Redrawn only on a theme change.
import { Container, Graphics } from "pixi.js";
import { worldCorners, type Vec } from "../projection.ts";
import {
  BLOCK, blockKey, GLYPH_AT, gridEdges, rimColor, terrainGlyph, terrainMark, topColor, zoneSegments,
  type Plate, type Scene,
} from "../scene.ts";
import type { RenderTheme } from "../theme.ts";
import type { Box } from "../projection.ts";

export interface Block {
  /** Index into Scene.levels. */
  level: number;
  box: Box;
  node: Container;
  /** Parts shown only from zoom stage Z1 (hex lines, terrain signs). */
  detail?: Graphics;
}

const flat = (ps: Vec[]) => ps.flatMap((p) => [p.x, p.y]);

/** A plate: every hex of the block whose column reaches the level, top colour or rim colour. */
export function drawPlate(scene: Scene, plate: Plate, theme: RenderTheme): Block {
  const g = new Graphics();
  for (const h of plate.hexes) {
    const hex = scene.hexById.get(h.id)!;
    const color = scene.levelOf.get(h.id) === plate.level
      ? topColor(hex, h, theme.map, scene.bounds)
      : rimColor(hex, h, plate.level, theme.map, scene.bounds, theme.camera.wallShade);
    g.poly(flat(worldCorners(scene.grid, h))).fill({ color });
  }
  return { level: plate.level, box: plate.box, node: g };
}

/**
 * Grid blocks: per level and block the hex lines (1 px, map.hexLine at shape.hexLineAlpha) and
 * terrain signs of the hexes whose top is on that level, plus the province borders drawn there.
 */
export function drawGrid(scene: Scene, theme: RenderTheme): Block[] {
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
    const zone = new Graphics();
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
        const a = corners[(i + 5) % 6]!, b = corners[i]!;
        detail.moveTo(a.x, a.y).lineTo(b.x, b.y);
      }
      for (const s of zones.get(id) ?? []) {
        zone.moveTo(s.a.x, s.a.y).lineTo(s.b.x, s.b.y);
        zoneLines++;
      }
    }
    detail.stroke({ width: 1, pixelLine: true, color: theme.map.hexLine, alpha: theme.hexLineAlpha });
    for (const id of ids) {
      const mark = terrainMark(scene.hexById.get(id)!);
      if (!mark) continue;
      const h = scene.grid.byId.get(id)!;
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
    node.addChild(detail, zone);
    out.push({ level, box, node, detail });
  }
  return out;
}

export { BLOCK };
