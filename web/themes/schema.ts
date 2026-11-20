// What a theme is (#95): every visual decision is a token. A theme is one JSON file in
// web/themes/ with exactly these keys; CSS variables and the PixiJS palette are both
// derived from it, nothing is hard-coded elsewhere.

export const COLOR_KEYS = {
  map: [
    "seaDeep", "seaShallow", "landLow", "land", "landHigh", "hexLine",
    // Laid-tile colour by the engine's tile.color (replaces the single `tile` of schema v1).
    "tileYellow", "tileGreen", "tileBrown", "tileGray", "tileRed", "tileEdge",
    "track", "city", "cityEdge", "edgeDot",
    "hill", "mountain", "water",
    "rail", "sleeper", "bed",
    "zoneBorder", "seaZoneLine", "ferry", "port", "impassable", "portPublic", "portPrivate", "oeRoute",
    // The two seas of the board (#449): north seas, Mediterranean and Black Sea; the circles of the sea zones.
    "seaNorth", "seaMed", "seaMarkNorth", "seaMarkMed", "seaMarkRing", "seaMarkInk",
    // Base surfaces (#477): the tint that lightens the sea towards the coast, and the foam along it.
    "seaCoast", "coastFoam",
    "label", "labelHalo", "valid", "selected", "invalid", "preview", "shadow",
  ],
  ui: ["bg", "panel", "panelAlt", "ink", "faint", "rule", "accent", "accentInk", "bar", "barInk", "error", "ok", "warn", "info", "overlay"],
  // Kurstafel as on the board (#478): dark board, light cells, price ink, red major par outline and its label, arrows, regional par mark.
  // Rundenanzeiger, Betriebsreihenfolge and port authority signs as on the board (slice 2): running round disc,
  // finished cell of the operating order, the two blue/green signs and their ink.
  stock: ["field", "cell", "cellInk", "major", "majorInk", "arrow", "par", "roundOn", "roundOnInk", "orderDone", "orderDoneInk", "signNorth", "signNorthInk", "signMed", "signMedInk"],
  // Fallback palette for company ids without an entry in `companies` (unknown or future ids).
  company: ["c1", "c2", "c3", "c4", "c5", "c6"],
  player: ["p1", "p2", "p3", "p4", "p5", "p6", "p7"],
} as const;

export type ColorGroup = keyof typeof COLOR_KEYS;
export type Colors<G extends ColorGroup> = Record<(typeof COLOR_KEYS)[G][number], string>;

export const TILE_STYLES = ["full", "inner"] as const;
export type TileStyle = (typeof TILE_STYLES)[number];
export type TrackColorMode = (typeof TRACK_COLOR_MODES)[number];
export type TrackColorPart = (typeof TRACK_COLOR_PARTS)[number];

export const FONT_KEYS = ["head", "body"] as const;
/** Type scale in px (#298): xs..xl steps, heading for panel titles, display for the top bar. Base size is `md`. */
export const TYPE_KEYS = ["xs", "sm", "md", "lg", "xl", "heading", "display"] as const;
/** Spacing scale in px (#298). */
export const SPACE_KEYS = ["xxs", "xs", "sm", "md", "lg", "xl", "xxl"] as const;
export const TILE_COLOR_KEYS = ["tileYellow", "tileGreen", "tileBrown", "tileGray", "tileRed"] as const;

/** Where the company colour sits on track (#11: not by builder; neutral is the owner's choice). */
export const TRACK_COLOR_MODES = ["builder", "neutral", "lastRun"] as const;
export const TRACK_COLOR_PARTS = ["bed", "sleepers", "rails"] as const;

/** Numeric tokens with their allowed range (ui-spec 1.3). Lengths are in hex side lengths. */
export const NUMBER_RANGES = {
  camera: {
    pitch: [0, 65], yaw: [-45, 45], heightLand: [0, 0.6], heightHill: [0, 1], heightMountain: [0, 1.5],
    heightTile: [0, 0.3], heightToken: [0, 0.6], wallShade: [0, 1], lightAzimuth: [0, 360], shadowAlpha: [0, 1],
    // Zoom (px per hex side) of "centre on the home station" (#415): at least this close, never zoomed out by it.
    homeZoom: [10, 60],
  },
  track: {
    gauge: [0.02, 0.3], railWidth: [0.005, 0.08], sleeperSpacing: [0.03, 0.3],
    sleeperLength: [0.05, 0.5], sleeperWidth: [0.01, 0.1], bedWidth: [0.05, 0.6],
    // Run band (#155) in side lengths: band width, light outline per side, sideways gap of several trains, width factor
    // with several trains, radius of a stop ring; and the least width on screen in px.
    runWidth: [0.05, 0.6], runOutline: [0, 0.1], runGap: [0.05, 0.5], runMultiScale: [0.3, 1], runRing: [0.05, 0.5], runMinPx: [0, 12],
  },
  motion: { runMsPerHex: [50, 1000], runMaxMs: [500, 20000], queueMaxMs: [500, 30000], flashMs: [100, 2000], flyMs: [0, 3000],
    // Touch (#259): decay time constant of the pan inertia, window of a double tap (ms).
    inertiaMs: [0, 2000], doubleTapMs: [100, 800],
    // Title screen slider (#460): time per picture and the fade between two, ms.
    titleSlideMs: [2000, 30000], titleFadeMs: [0, 4000] },
  type: { xs: [9, 14], sm: [10, 16], md: [11, 18], lg: [12, 22], xl: [14, 26], heading: [14, 30], display: [16, 36] },
  space: { xxs: [1, 8], xs: [2, 12], sm: [4, 16], md: [4, 20], lg: [6, 24], xl: [8, 32], xxl: [8, 48] },
  shape: {
    hexLineAlpha: [0, 1], paper: [0, 1], radius: [0, 24], barHeight: [32, 96], sideWidth: [240, 480], gap: [4, 24], hit: [32, 64],
    // Panel metrics in px (#298): floating action panel width, top bar height, panel corner radius.
    panelWidth: [240, 400], topbarHeight: [40, 64], panelRadius: [0, 24],
    // Portrait bottom sheet (#333): largest share of the body height the open sheet may take, in percent.
    sheetMaxHeight: [30, 70],
    // Map strokes in hex side lengths (they scale with the map like printed lines), alpha 0..1 (#44).
    zoneLine: [0.01, 0.3], focusLine: [0.01, 0.3], targetAlpha: [0, 1],
    // Soft coast (#100): Chaikin cut ratio (0 = hard hex outline) and noise amplitude in side lengths.
    coastRound: [0, 0.5], coastNoise: [0, 0.3],
    // Soft terrain blobs on the land (hills, mountains, water terrain): factor on their alpha, 0 = none (the terrain
    // signs of the board carry the information instead, #450).
    terrainBlobAlpha: [0, 1],
    // Red hexes (#453): 1 = the revenue box of the board (a white box with the values, the name below), 0 = the wedge
    // and the text mark.
    offboardBox: [0, 1],
    // Terrain signs (#450): 1 = the signs of the board (a coloured dome, mountain or shield with the cost in it), 0 = the
    // line glyph and the cost beside it.
    terrainSymbols: [0, 1],
    // Ferry lines (#452), in side lengths: width of the blue line, half width of the oval with the distance.
    ferryWidth: [0.02, 0.25], ferryOval: [0.06, 0.4],
    // Sea (#449): 1 = the sea tinted by its sea (seaNorth, seaMed), 0 = the gradient seaDeep to seaShallow; factor on the
    // alpha of the hex lines between sea hexes (0 = none); sea zone boundary dashes, gap and width and the radius of the
    // zone circles, in side lengths.
    seaTint: [0, 1], seaHexLineAlpha: [0, 1], seaZoneDash: [0.05, 1], seaZoneGap: [0.05, 1], seaZoneWidth: [0.005, 0.2], seaMarkRadius: [0.15, 1],
    // Zone lines of the board (#477), in side lengths: ring of the zone circles as a fraction of their radius; the black
    // dashed track-rights boundary: dash, gap and width.
    seaMarkRing: [0.02, 0.4], rightsDash: [0.05, 1.5], rightsGap: [0.05, 1.5], rightsWidth: [0.02, 0.4],
    // Base surfaces (#477), in side lengths: how far the sea gradient reaches from the coast, the alpha it has at the coast;
    // width and alpha of the foam fringe (0 = none).
    seaReach: [0, 20], seaCoastAlpha: [0, 1], coastFoamWidth: [0, 1], coastFoamAlpha: [0, 1],
    // Cities, towns and tokens (#147), in side lengths: slot circle, token cylinder, town bar.
    slotRadius: [0.05, 0.35], tokenRadius: [0.04, 0.3], townLength: [0.1, 0.6], townWidth: [0.02, 0.2],
    // Arrow at the middle end of a port stub in a sea hex (#444), in side lengths: length along the stub, width across.
    portArrowLength: [0.1, 0.6], portArrowWidth: [0.08, 0.5],
    // Port badge with the anchor (#451), radius in side lengths.
    portMark: [0.08, 0.4],
    // Place names (#455): zoom from which they show (hex side in px), offset below the hex centre in side lengths.
    nameZoom: [4, 80], nameOffset: [0, 1],
    // Hit radius and drag threshold in px (#259): mouse and touch. 22 px radius = Apple's 44 px minimum target.
    hitPx: [4, 40], hitTouchPx: [16, 48], dragPx: [1, 20], dragTouchPx: [4, 30],
  },
} as const satisfies Record<string, Record<string, readonly [number, number]>>;

export const CAMERA_KEYS = Object.keys(NUMBER_RANGES.camera) as (keyof typeof NUMBER_RANGES.camera)[];
export const TRACK_KEYS = [...Object.keys(NUMBER_RANGES.track), "colorMode", "colorPart"] as const;
export const MOTION_KEYS = [...Object.keys(NUMBER_RANGES.motion), "enabled"] as const;
export const TYPE_SCALE_KEYS = Object.keys(NUMBER_RANGES.type) as (keyof typeof NUMBER_RANGES.type)[];
export const SPACE_SCALE_KEYS = Object.keys(NUMBER_RANGES.space) as (keyof typeof NUMBER_RANGES.space)[];
export const SHAPE_KEYS = ["tileStyle", "shadow", ...Object.keys(NUMBER_RANGES.shape)] as const;
export const TOP_KEYS = ["id", "name", "colorScheme", "map", "ui", "stock", "company", "companies", "player", "font", "camera", "track", "motion", "shape", "type", "space"] as const;

/** Colours of one company (#99): seal/token background, text on it, edge. Ink is checked for 4.5:1 by the specs. */
export const COMPANY_COLOR_KEYS = ["bg", "ink", "edge"] as const;
export type CompanyColors = Record<(typeof COMPANY_COLOR_KEYS)[number], string>;

export interface Theme {
  id: string;
  name: string;
  colorScheme: "light" | "dark";
  map: Colors<"map">;
  ui: Colors<"ui">;
  stock: Colors<"stock">;
  company: Colors<"company">;
  /** Real company colours by company id (engine sym), derived from the engine by themes/derive-companies.ts. */
  companies: Record<string, CompanyColors>;
  player: Colors<"player">;
  font: Record<(typeof FONT_KEYS)[number], string>;
  camera: Record<keyof typeof NUMBER_RANGES.camera, number>;
  track: Record<keyof typeof NUMBER_RANGES.track, number> & { colorMode: TrackColorMode; colorPart: TrackColorPart };
  motion: Record<keyof typeof NUMBER_RANGES.motion, number> & {
    /** Overridden by prefers-reduced-motion and the player's setting. */
    enabled: boolean;
  };
  /** Font sizes in px (#298). */
  type: Record<keyof typeof NUMBER_RANGES.type, number>;
  /** Spacing in px (#298). */
  space: Record<keyof typeof NUMBER_RANGES.space, number>;
  shape: Record<keyof typeof NUMBER_RANGES.shape, number> & {
    /** Laid tiles fill the whole hex ("full", like the physical board) or leave a rim ("inner"). */
    tileStyle: TileStyle;
    /** CSS box-shadow of the panels. */
    shadow: string;
  };
}

const HEX = /^#[0-9a-f]{6}$/;

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function keyProblems(where: string, value: unknown, expected: readonly string[]): string[] {
  if (!isRecord(value)) return [`${where}: not an object`];
  const have = Object.keys(value);
  return [
    ...expected.filter((k) => !have.includes(k)).map((k) => `${where}.${k}: missing`),
    ...have.filter((k) => !expected.includes(k)).map((k) => `${where}.${k}: unknown key`),
  ];
}

function inRange(where: string, v: unknown, min: number, max: number): string[] {
  return typeof v === "number" && v >= min && v <= max ? [] : [`${where}: expected a number from ${min} to ${max}`];
}

/** Every reason why `raw` is not a complete theme; empty when it is one. */
export function themeProblems(raw: unknown): string[] {
  const problems = keyProblems("theme", raw, TOP_KEYS);
  if (!isRecord(raw)) return problems;
  if (typeof raw.id !== "string" || !/^[a-z][a-z0-9-]*$/.test(raw.id)) problems.push("theme.id: expected a lower-case id");
  if (typeof raw.name !== "string" || raw.name === "") problems.push("theme.name: expected a name");
  if (raw.colorScheme !== "light" && raw.colorScheme !== "dark") problems.push("theme.colorScheme: expected light or dark");
  for (const group of Object.keys(COLOR_KEYS) as ColorGroup[]) {
    const colors = raw[group];
    problems.push(...keyProblems(group, colors, COLOR_KEYS[group]));
    if (!isRecord(colors)) continue;
    for (const [k, v] of Object.entries(colors)) {
      if (typeof v !== "string" || !HEX.test(v)) problems.push(`${group}.${k}: expected a colour like #1a2b3c`);
    }
  }
  if (!isRecord(raw.companies)) problems.push("companies: not an object");
  else {
    for (const [id, entry] of Object.entries(raw.companies)) {
      problems.push(...keyProblems(`companies.${id}`, entry, COMPANY_COLOR_KEYS));
      if (!isRecord(entry)) continue;
      for (const [k, v] of Object.entries(entry)) {
        if (typeof v !== "string" || !HEX.test(v)) problems.push(`companies.${id}.${k}: expected a colour like #1a2b3c`);
      }
    }
  }
  problems.push(...keyProblems("font", raw.font, FONT_KEYS));
  if (isRecord(raw.font)) {
    for (const k of FONT_KEYS) if (typeof raw.font[k] !== "string" || raw.font[k] === "") problems.push(`font.${k}: expected a font stack`);
  }
  for (const [group, keys] of [["camera", CAMERA_KEYS], ["track", TRACK_KEYS], ["motion", MOTION_KEYS], ["shape", SHAPE_KEYS], ["type", TYPE_SCALE_KEYS], ["space", SPACE_SCALE_KEYS]] as const) {
    problems.push(...keyProblems(group, raw[group], keys));
    const values = raw[group];
    if (!isRecord(values)) continue;
    const ranges: Record<string, readonly [number, number]> = NUMBER_RANGES[group];
    for (const [k, [min, max]] of Object.entries(ranges)) if (k in values) problems.push(...inRange(`${group}.${k}`, values[k], min, max));
  }
  if (isRecord(raw.track)) {
    const t = raw.track;
    if (!TRACK_COLOR_MODES.includes(t.colorMode as TrackColorMode)) problems.push("track.colorMode: expected builder, neutral or lastRun");
    if (!TRACK_COLOR_PARTS.includes(t.colorPart as TrackColorPart)) problems.push("track.colorPart: expected bed, sleepers or rails");
    const [g, rw, sl, bw] = [t.gauge, t.railWidth, t.sleeperLength, t.bedWidth];
    if ([g, rw, sl, bw].every((v) => typeof v === "number")) {
      // Geometry must hold together: sleepers reach past both rails, the bed past the sleepers.
      if ((sl as number) < (g as number) + (rw as number)) problems.push("track.sleeperLength: shorter than gauge + railWidth");
      if ((bw as number) < (sl as number)) problems.push("track.bedWidth: narrower than sleeperLength");
    }
  }
  if (isRecord(raw.motion)) {
    const m = raw.motion;
    if (typeof m.enabled !== "boolean") problems.push("motion.enabled: expected true or false");
    if (typeof m.runMaxMs === "number" && typeof m.queueMaxMs === "number" && m.queueMaxMs < m.runMaxMs) problems.push("motion.queueMaxMs: shorter than runMaxMs");
  }
  for (const [group, keys] of [["type", TYPE_SCALE_KEYS], ["space", SPACE_SCALE_KEYS]] as const) {
    const v = raw[group];
    if (!isRecord(v)) continue;
    // Scales climb: a larger step is never smaller than the one before.
    for (let i = 1; i < keys.length; i++) {
      const [a, b] = [v[keys[i - 1]!], v[keys[i]!]];
      if (typeof a === "number" && typeof b === "number" && b < a) problems.push(`${group}.${keys[i]}: smaller than ${keys[i - 1]}`);
    }
  }
  if (isRecord(raw.shape)) {
    // Touch targets on the iPad (CLAUDE.md rule 18): at least 44 px.
    if (typeof raw.shape.hit === "number" && raw.shape.hit < 44) problems.push("shape.hit: touch targets need at least 44");
    if (!TILE_STYLES.includes(raw.shape.tileStyle as TileStyle)) problems.push("shape.tileStyle: expected full or inner");
    if (typeof raw.shape.shadow !== "string" || raw.shape.shadow === "") problems.push("shape.shadow: expected a CSS box-shadow");
  }
  return problems;
}

/**
 * Brings a schema-v1 theme (#95) to v2 where the old values map onto new ones:
 * `shape.tilt` becomes `camera.pitch = acos(tilt)` in degrees and is removed,
 * `map.tile` becomes the five `map.tile*` colours. Anything else new stays missing
 * and is reported by `themeProblems`. Does not modify its argument.
 */
export function migrateTheme(raw: unknown): unknown {
  if (!isRecord(raw)) return raw;
  const out: Record<string, unknown> = { ...raw };
  if (isRecord(raw.shape) && "tilt" in raw.shape) {
    const { tilt, ...shape } = raw.shape;
    out.shape = shape;
    if (typeof tilt === "number" && tilt >= 0 && tilt <= 1 && !("camera" in raw)) {
      out.camera = { pitch: Math.round((Math.acos(tilt) * 180) / Math.PI * 10) / 10 };
    }
  }
  if (isRecord(raw.map) && "tile" in raw.map) {
    const { tile, ...map } = raw.map;
    out.map = { ...Object.fromEntries(TILE_COLOR_KEYS.map((k) => [k, tile])), ...map };
  }
  return out;
}

export function parseTheme(raw: unknown): Theme {
  const problems = themeProblems(raw);
  if (problems.length > 0) throw new Error(`Invalid theme: ${problems.join("; ")}`);
  return raw as Theme;
}

export function isTileStyle(v: unknown): v is TileStyle {
  return TILE_STYLES.includes(v as TileStyle);
}
