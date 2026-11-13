// Preview on the map (#48 track, #174 token): what the chosen action would put on the board, before the
// player confirms it (owner's decision #137: a confirmation step instead of undo). `MapView.setPreview`
// calls `buildPreview`; the result goes into the overlay container of the hex's height level, so it covers
// the tile below and the valid-target fill, but not the hexes in front of it.
//
// Tile: the catalog tile (GET /map `tiles`) in the chosen rotation, drawn like a laid tile (surface, track,
// nodes) and outlined in `map.selected`. Token: a disc in the company colour on the first free slot of the
// chosen city, outlined in `map.selected`. Both slightly transparent, so they read as "not yet laid".
import { Container, Graphics } from "pixi.js";
import { drawTileSurface } from "./layers/tiles.ts";
import { drawNodes } from "./layers/nodes.ts";
import type { MapPreview } from "./map.ts";
import type { MapGeometry } from "./mapdata.ts";
import { worldCorners } from "./projection.ts";
import type { Scene } from "./scene.ts";
import type { Slot } from "./stones.ts";
import type { RenderTheme } from "./theme.ts";
import { drawTrack, type TrackNode } from "./track.ts";
import { tileGeometry, type HexFrame } from "./track-axes.ts";

/** Opacity of a preview: visibly not yet part of the board. ASSUMPTION (no spec value), theme token later if needed. */
export const PREVIEW_ALPHA = 0.88;

export interface PreviewContext {
  scene: Scene;
  theme: RenderTheme;
  frame: HexFrame;
  tiles: MapGeometry["tiles"];
  /** Token slots of the tile now on the hex (hex coordinates). */
  slotsOf: (hex: string) => Slot[];
  /** Tokens already in city `city` of the hex. */
  tokensIn: (hex: string, city: number) => number;
  corpColor: (corp: string) => number;
}

export interface PreviewNode {
  node: Container;
  /** Height level of the hex (index into the overlay containers). */
  level: number;
  /** Track of a tile preview, so the map can follow the zoom stage like for laid tiles. */
  track: TrackNode | null;
}

/** Catalog key of a tile: actions carry tile ids ("9-4"), the catalog uses names ("9"). */
export function tileName(tile: string, tiles: MapGeometry["tiles"]): string {
  if (tiles?.[tile]) return tile;
  return tile.replace(/-\d+$/, "");
}

/** The preview as a container in flat world coordinates; null when hex, tile or slot is unknown. */
export function buildPreview(p: MapPreview, ctx: PreviewContext): PreviewNode | null {
  if (!p) return null;
  const { scene, theme } = ctx;
  const g = scene.grid.byId.get(p.hex);
  const level = scene.levelOf.get(p.hex);
  if (!g || level === undefined) return null;
  const origin = { x: g.x, y: g.y };
  const node = new Container({ label: `preview ${p.hex}` });
  node.alpha = PREVIEW_ALPHA;
  const outline = new Graphics();
  let track: TrackNode | null = null;
  if ("tile" in p) {
    const parts = ctx.tiles?.[tileName(p.tile, ctx.tiles)];
    if (!parts) return null;
    const geom = tileGeometry(parts, p.rotation, ctx.frame);
    const surface = drawTileSurface(scene.grid, g, parts.color ?? "yellow", theme);
    if (surface) node.addChild(surface);
    if (geom.axes.length) {
      track = drawTrack(geom.axes, origin, theme);
      node.addChild(track.node);
    }
    if (geom.nodes.length) node.addChild(drawNodes({ parts, nodes: geom.nodes, axes: geom.axes, frame: ctx.frame, origin }, theme));
    outline.poly(worldCorners(scene.grid, g).flatMap((q) => [q.x, q.y])).stroke({ width: theme.focusLine, color: theme.map.selected, join: "round" });
  } else {
    const slots = ctx.slotsOf(p.hex).filter((s) => s.city === p.city).sort((a, b) => a.slot - b.slot);
    const slot = slots[ctx.tokensIn(p.hex, p.city)] ?? slots[0];
    if (!slot) return null;
    const x = origin.x + slot.pos.x, y = origin.y + slot.pos.y;
    outline.circle(x, y, theme.slotRadius * 0.92).fill({ color: ctx.corpColor(p.corp) })
      .circle(x, y, theme.slotRadius * 1.15).stroke({ width: theme.focusLine, color: theme.map.selected });
  }
  node.addChild(outline);
  return { node, level, track };
}
