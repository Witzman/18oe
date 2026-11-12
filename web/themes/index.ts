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
