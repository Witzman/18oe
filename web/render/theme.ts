// The active theme in the form PixiJS wants (numeric colours). Same source as the CSS
// variables: web/themes/*.json. No colour is written down here.
import { choiceFromRoot, type Choice, type Root } from "../themes/choice.ts";
import { hexToNumber } from "../themes/color.ts";
import { COLOR_KEYS, type ColorGroup, type Theme, type TileStyle } from "../themes/schema.ts";

type Numeric<G extends ColorGroup> = Record<(typeof COLOR_KEYS)[G][number], number>;

export interface RenderTheme {
  id: string;
  map: Numeric<"map">;
  ui: Numeric<"ui">;
  company: Numeric<"company">;
  player: Numeric<"player">;
  tilt: number;
  tileStyle: TileStyle;
  hexLineAlpha: number;
  paper: number;
}

function numeric<G extends ColorGroup>(theme: Theme, group: G): Numeric<G> {
  const colors: Record<string, string> = theme[group];
  return Object.fromEntries(COLOR_KEYS[group].map((k) => [k, hexToNumber(colors[k]!)])) as Numeric<G>;
}

export function renderTheme(choice: Pick<Choice, "theme" | "tileStyle">): RenderTheme {
  const t = choice.theme;
  return {
    id: t.id,
    map: numeric(t, "map"),
    ui: numeric(t, "ui"),
    company: numeric(t, "company"),
    player: numeric(t, "player"),
    tilt: t.shape.tilt,
    tileStyle: choice.tileStyle,
    hexLineAlpha: t.shape.hexLineAlpha,
    paper: t.shape.paper,
  };
}

/** What is on screen right now, read from the root element's data attributes. */
export function currentRenderTheme(root: Root = document.documentElement): RenderTheme {
  return renderTheme(choiceFromRoot(root));
}
