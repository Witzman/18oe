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
  stock: Numeric<"stock">;
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
  /** Soft coast (#100): Chaikin cut ratio and noise amplitude in side lengths. */
  coastRound: number;
  coastNoise: number;
  /** Factor on the alpha of the soft terrain blobs on the land, 0 = none. */
  terrainBlobAlpha: number;
  /** Red hexes: 1 = revenue box like the board, 0 = wedge and text mark (#453). */
  offboardBox: number;
  /** Terrain: 1 = coloured signs with the cost in them, 0 = line glyph and text mark (#450). */
  terrainSymbols: number;
  /** Ferry line width and half width of the distance oval, in side lengths (#452). */
  ferryWidth: number;
  ferryOval: number;
  /** Sea (#449): tint by sea, factor on the sea hex line alpha, sea zone dashes and circle, in side lengths. */
  seaTint: number;
  seaHexLineAlpha: number;
  seaZoneDash: number;
  seaZoneGap: number;
  seaZoneWidth: number;
  seaMarkRadius: number;
  /** Base surfaces (#477): sea gradient reach and alpha at the coast, foam width and alpha. */
  seaReach: number;
  seaCoastAlpha: number;
  coastFoamWidth: number;
  coastFoamAlpha: number;
  /** Cities, towns and tokens in side lengths (#147). */
  slotRadius: number;
  tokenRadius: number;
  townLength: number;
  townWidth: number;
  /** Arrow at the middle end of a port stub in a sea hex, in side lengths (#444). */
  portArrowLength: number;
  portArrowWidth: number;
  portMark: number;
  /** Place names (#455): zoom (hex side in px) from which they show, and their offset below the hex centre in side lengths. */
  nameZoom: number;
  nameOffset: number;
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
    stock: numeric(t, "stock"),
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
    coastRound: t.shape.coastRound,
    coastNoise: t.shape.coastNoise,
    terrainBlobAlpha: t.shape.terrainBlobAlpha,
    offboardBox: t.shape.offboardBox,
    terrainSymbols: t.shape.terrainSymbols,
    ferryWidth: t.shape.ferryWidth,
    ferryOval: t.shape.ferryOval,
    seaTint: t.shape.seaTint,
    seaHexLineAlpha: t.shape.seaHexLineAlpha,
    seaZoneDash: t.shape.seaZoneDash,
    seaZoneGap: t.shape.seaZoneGap,
    seaZoneWidth: t.shape.seaZoneWidth,
    seaMarkRadius: t.shape.seaMarkRadius,
    seaReach: t.shape.seaReach,
    seaCoastAlpha: t.shape.seaCoastAlpha,
    coastFoamWidth: t.shape.coastFoamWidth,
    coastFoamAlpha: t.shape.coastFoamAlpha,
    slotRadius: t.shape.slotRadius,
    tokenRadius: t.shape.tokenRadius,
    townLength: t.shape.townLength,
    townWidth: t.shape.townWidth,
    portArrowLength: t.shape.portArrowLength,
    portArrowWidth: t.shape.portArrowWidth,
    portMark: t.shape.portMark,
    nameZoom: t.shape.nameZoom,
    nameOffset: t.shape.nameOffset,
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
