// Which theme the viewer picked: kept in localStorage, shown as data attributes on the root element.
// CSS reads the attributes (themes.css), PixiJS reads the same choice through render/theme.ts.
import { DEFAULT_THEME_ID, themeById } from "./index.ts";
import { isTileStyle, type Theme, type TileStyle } from "./schema.ts";

export const THEME_KEY = "oe.theme";
export const TILE_STYLE_KEY = "oe.tileStyle";

export interface Choice {
  theme: Theme;
  /** Effective tile style: the viewer's override, else the theme's own. */
  tileStyle: TileStyle;
  /** True when the viewer overrode the theme's tile style. */
  tileStyleOverridden: boolean;
}

export type KeyValue = Pick<Storage, "getItem" | "setItem" | "removeItem">;
export interface Root { dataset: Record<string, string | undefined> }

// Storage can be unavailable or throw (private mode); the choice then just does not persist.
function read(storage: KeyValue | null, key: string): string | null {
  try { return storage?.getItem(key) ?? null; } catch { return null; }
}

export function loadChoice(storage: KeyValue | null): Choice {
  const theme = themeById(read(storage, THEME_KEY) ?? DEFAULT_THEME_ID);
  const stored = read(storage, TILE_STYLE_KEY);
  const overridden = isTileStyle(stored);
  return { theme, tileStyle: overridden ? stored : theme.shape.tileStyle, tileStyleOverridden: overridden };
}

export function saveTheme(storage: KeyValue | null, id: string): void {
  try { storage?.setItem(THEME_KEY, themeById(id).id); } catch { /* not persisted */ }
}

/** `null` clears the override, the theme's own tile style applies again. */
export function saveTileStyle(storage: KeyValue | null, style: TileStyle | null): void {
  try {
    if (style === null) storage?.removeItem(TILE_STYLE_KEY);
    else storage?.setItem(TILE_STYLE_KEY, style);
  } catch { /* not persisted */ }
}

export function applyChoice(root: Root, choice: Choice): void {
  root.dataset.theme = choice.theme.id;
  root.dataset.tileStyle = choice.tileStyle;
}

export function choiceFromRoot(root: Root): Choice {
  const theme = themeById(root.dataset.theme);
  const style = root.dataset.tileStyle;
  const overridden = isTileStyle(style) && style !== theme.shape.tileStyle;
  return { theme, tileStyle: isTileStyle(style) ? style : theme.shape.tileStyle, tileStyleOverridden: overridden };
}
