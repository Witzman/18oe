// Tiles layer (ui-spec 2.3 layer 6, 2.5): one container per hex, redrawn only when that hex's
// entry in state.map changes. This issue (#44) draws the tile surface only: a full hex in
// map.tile<Colour> (inset 12 % when tileStyle is "inner"); printed white/blue tiles have none.
// Track (#146, track.ts) is drawn into the same per-hex container; cities and tokens (#147) are drawn into the same per-hex container later.
import { Graphics } from "pixi.js";
import { worldCorners, type GridHex, type HexGrid } from "../projection.ts";
import type { RenderTheme } from "../theme.ts";

const TILE_COLOR = { yellow: "tileYellow", green: "tileGreen", brown: "tileBrown", gray: "tileGray", red: "tileRed" } as const;

/** Inset of an inner-style tile, fraction of the radius (ui-spec 2.5). */
export const INNER_INSET = 0.12;

export function tileColor(color: string | undefined, theme: RenderTheme): number | null {
  const key = TILE_COLOR[color as keyof typeof TILE_COLOR];
  return key ? theme.map[key] : null;
}

/** Surface of the tile on hex h, or null when the tile has no coloured surface. */
export function drawTileSurface(grid: HexGrid, h: GridHex, color: string | undefined, theme: RenderTheme): Graphics | null {
  const fill = tileColor(color, theme);
  if (fill === null) return null;
  const k = theme.tileStyle === "inner" ? 1 - INNER_INSET : 1;
  const pts = worldCorners(grid, h).flatMap((p) => [h.x + (p.x - h.x) * k, h.y + (p.y - h.y) * k]);
  return new Graphics().poly(pts).fill({ color: fill });
}
