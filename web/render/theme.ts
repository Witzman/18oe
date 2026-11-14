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
  /** Company colours by company id (#99), numeric. */
  companies: Record<string, { bg: number; ink: number; edge: number }>;
  player: Numeric<"player">;
  camera: Theme["camera"];
  track: Theme["track"];
  motion: Theme["motion"];
  tileStyle: TileStyle;
  hexLineAlpha: number;
  paper: number;
  /** Map strokes in hex side lengths and the fill alpha of valid targets (#44). */
  zoneLine: number;
  focusLine: number;
  targetAlpha: number;
  /** Cities, towns and tokens in side lengths (#147). */
  slotRadius: number;
  tokenRadius: number;
  townLength: number;
  townWidth: number;
  /** Hit radius and drag threshold in px, mouse and touch (#259). */
  hitPx: number;
  hitTouchPx: number;
  dragPx: number;
  dragTouchPx: number;
  font: Theme["font"];
  /** Panel metrics in px (CSS reads them as --shape-*). */
  barHeight: number;
  sideWidth: number;
  gap: number;
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
    companies: Object.fromEntries(Object.entries(t.companies).map(([id, c]) => [id, { bg: hexToNumber(c.bg), ink: hexToNumber(c.ink), edge: hexToNumber(c.edge) }])),
    player: numeric(t, "player"),
    camera: { ...t.camera },
    track: { ...t.track },
    motion: { ...t.motion },
    tileStyle: choice.tileStyle,
    hexLineAlpha: t.shape.hexLineAlpha,
    paper: t.shape.paper,
    zoneLine: t.shape.zoneLine,
    focusLine: t.shape.focusLine,
    targetAlpha: t.shape.targetAlpha,
    slotRadius: t.shape.slotRadius,
    tokenRadius: t.shape.tokenRadius,
    townLength: t.shape.townLength,
    townWidth: t.shape.townWidth,
    hitPx: t.shape.hitPx,
    hitTouchPx: t.shape.hitTouchPx,
    dragPx: t.shape.dragPx,
    dragTouchPx: t.shape.dragTouchPx,
    font: { ...t.font },
    barHeight: t.shape.barHeight,
    sideWidth: t.shape.sideWidth,
    gap: t.shape.gap,
  };
}

/** What is on screen right now, read from the root element's data attributes. */
export function currentRenderTheme(root: Root = document.documentElement): RenderTheme {
  return renderTheme(choiceFromRoot(root));
}
