// Text in the world of the map (#453, #450): drawn large and scaled down into the hex, so it stays sharp when the map is
// zoomed in, and sized in side lengths like everything else on the tiles. Used by the revenue boxes of the red hexes
// and the terrain signs.
import { Text } from "pixi.js";
import type { RenderTheme } from "./theme.ts";

/** Text pixels per font unit, and the render resolution. */
export const FONT_PX = 32, TEXT_RES = 3;

/** A bold text of `size` side lengths at `at` (hex coordinates plus origin), centred; `halo` draws a rim in that colour. */
export function worldText(text: string, size: number, color: number, theme: Pick<RenderTheme, "font">, at: { x: number; y: number }, halo?: number, look: { italic?: boolean; alpha?: number } = {}): Text {
  const t = new Text({
    text, resolution: TEXT_RES,
    style: { fontFamily: theme.font.body, fontSize: FONT_PX, fontWeight: "700", ...(look.italic ? { fontStyle: "italic" as const } : {}), fill: color, align: "center", ...(halo === undefined ? {} : { stroke: { color: halo, width: 7, join: "round" as const } }) },
  });
  t.anchor.set(0.5);
  t.scale.set(size / FONT_PX);
  t.position.set(at.x, at.y);
  if (look.alpha !== undefined) t.alpha = look.alpha;
  return t;
}
