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
    "zoneBorder", "seaZoneLine", "ferry", "port", "oeRoute",
    "label", "labelHalo", "valid", "selected", "invalid", "preview", "shadow",
  ],
  ui: ["bg", "panel", "panelAlt", "ink", "faint", "rule", "accent", "accentInk", "bar", "barInk", "error", "ok", "warn", "info", "overlay"],
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
export const TILE_COLOR_KEYS = ["tileYellow", "tileGreen", "tileBrown", "tileGray", "tileRed"] as const;

/** Where the company colour sits on track (#11: not by builder; neutral is the owner's choice). */
export const TRACK_COLOR_MODES = ["builder", "neutral", "lastRun"] as const;
export const TRACK_COLOR_PARTS = ["bed", "sleepers", "rails"] as const;

/** Numeric tokens with their allowed range (ui-spec 1.3). Lengths are in hex side lengths. */
export const NUMBER_RANGES = {
  camera: {
    pitch: [0, 65], yaw: [-45, 45], heightLand: [0, 0.6], heightHill: [0, 1], heightMountain: [0, 1.5],
    heightTile: [0, 0.3], heightToken: [0, 0.6], wallShade: [0, 1], lightAzimuth: [0, 360], shadowAlpha: [0, 1],
  },
  track: {
    gauge: [0.02, 0.3], railWidth: [0.005, 0.08], sleeperSpacing: [0.03, 0.3],
    sleeperLength: [0.05, 0.5], sleeperWidth: [0.01, 0.1], bedWidth: [0.05, 0.6],
  },
  motion: { runMsPerHex: [50, 1000], runMaxMs: [500, 20000], queueMaxMs: [500, 30000], flashMs: [100, 2000], flyMs: [0, 3000] },
  shape: {
    hexLineAlpha: [0, 1], paper: [0, 1], radius: [0, 24], barHeight: [32, 96], sideWidth: [240, 480], gap: [4, 24],
    // Map strokes in hex side lengths (they scale with the map like printed lines), alpha 0..1 (#44).
    zoneLine: [0.01, 0.3], focusLine: [0.01, 0.3], targetAlpha: [0, 1],
    // Cities, towns and tokens (#147), in side lengths: slot circle, token cylinder, town bar.
    slotRadius: [0.05, 0.35], tokenRadius: [0.04, 0.3], townLength: [0.1, 0.6], townWidth: [0.02, 0.2],
  },
} as const satisfies Record<string, Record<string, readonly [number, number]>>;

export const CAMERA_KEYS = Object.keys(NUMBER_RANGES.camera) as (keyof typeof NUMBER_RANGES.camera)[];
export const TRACK_KEYS = [...Object.keys(NUMBER_RANGES.track), "colorMode", "colorPart"] as const;
export const MOTION_KEYS = [...Object.keys(NUMBER_RANGES.motion), "enabled"] as const;
export const SHAPE_KEYS = ["tileStyle", "shadow", ...Object.keys(NUMBER_RANGES.shape)] as const;
export const TOP_KEYS = ["id", "name", "colorScheme", "map", "ui", "company", "companies", "player", "font", "camera", "track", "motion", "shape"] as const;

/** Colours of one company (#99): seal/token background, text on it, edge. Ink is checked for 4.5:1 by the specs. */
export const COMPANY_COLOR_KEYS = ["bg", "ink", "edge"] as const;
export type CompanyColors = Record<(typeof COMPANY_COLOR_KEYS)[number], string>;

export interface Theme {
  id: string;
  name: string;
  colorScheme: "light" | "dark";
  map: Colors<"map">;
  ui: Colors<"ui">;
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
  for (const [group, keys] of [["camera", CAMERA_KEYS], ["track", TRACK_KEYS], ["motion", MOTION_KEYS], ["shape", SHAPE_KEYS]] as const) {
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
  if (isRecord(raw.shape)) {
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
