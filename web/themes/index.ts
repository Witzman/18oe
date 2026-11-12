// Schema v2 (#142). ASSUMPTIONS (Rule 10), all guessed and to be tuned by eye once the map
// renders: every camera.* height/shade/shadow value of both themes (Brett = ui-spec 1.3 start
// values; Atlas flatter and lighter on my own judgement), the five tile colours other than
// yellow (green, brown, gray, red were never specified), map.hill/mountain/water/zoneBorder/
// seaZoneLine/ferry/port/oeRoute/valid/selected/invalid/preview/shadow, ui.ok/warn/info/
// overlay/panelAlt, the track.* geometry of Atlas, and the motion timings. Decided by the owner
// (#11): neutral track (colorMode "neutral"), half-3D camera (pitch > 0), full-hex tiles.
// The themes that ship. Adding one: a JSON file here with every key from schema.ts, then list it below.
import atlas from "./atlas.json" with { type: "json" };
import brett from "./brett.json" with { type: "json" };
import { parseTheme, type Theme } from "./schema.ts";

export const themes: readonly Theme[] = [parseTheme(brett), parseTheme(atlas)];
export const DEFAULT_THEME_ID = "brett";

export function themeById(id: string | null | undefined): Theme {
  const found = themes.find((t) => t.id === id) ?? themes.find((t) => t.id === DEFAULT_THEME_ID);
  if (!found) throw new Error("No default theme");
  return found;
}
