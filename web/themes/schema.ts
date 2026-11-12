// What a theme is (#95): every visual decision is a token. A theme is one JSON file in
// web/themes/ with exactly these keys; CSS variables and the PixiJS palette are both
// derived from it, nothing is hard-coded elsewhere.

export const COLOR_KEYS = {
  map: ["seaDeep", "seaShallow", "landLow", "land", "landHigh", "hexLine", "tile", "tileEdge", "track", "city", "cityEdge", "edgeDot"],
  ui: ["bg", "panel", "ink", "faint", "rule", "accent", "accentInk", "bar", "barInk", "error"],
  // Placeholders until the real company colours come from the engine.
  company: ["c1", "c2", "c3", "c4", "c5", "c6"],
  player: ["p1", "p2", "p3", "p4", "p5", "p6", "p7"],
} as const;

export type ColorGroup = keyof typeof COLOR_KEYS;
export type Colors<G extends ColorGroup> = Record<(typeof COLOR_KEYS)[G][number], string>;

export const TILE_STYLES = ["full", "inner"] as const;
export type TileStyle = (typeof TILE_STYLES)[number];

export const FONT_KEYS = ["head", "body"] as const;
export const SHAPE_KEYS = ["tilt", "tileStyle", "hexLineAlpha", "paper", "radius"] as const;
export const TOP_KEYS = ["id", "name", "colorScheme", "map", "ui", "company", "player", "font", "shape"] as const;

export interface Theme {
  id: string;
  name: string;
  colorScheme: "light" | "dark";
  map: Colors<"map">;
  ui: Colors<"ui">;
  company: Colors<"company">;
  player: Colors<"player">;
  font: Record<(typeof FONT_KEYS)[number], string>;
  shape: {
    /** Vertical squash of the map: 1 = straight top-down view, 0.55 = tilted. */
    tilt: number;
    /** Laid tiles fill the whole hex ("full", like the physical board) or leave a rim ("inner"). */
    tileStyle: TileStyle;
    hexLineAlpha: number;
    /** Paper grain strength, 0 = none. */
    paper: number;
    /** Corner radius of panels in px. */
    radius: number;
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
  problems.push(...keyProblems("font", raw.font, FONT_KEYS));
  if (isRecord(raw.font)) {
    for (const k of FONT_KEYS) if (typeof raw.font[k] !== "string" || raw.font[k] === "") problems.push(`font.${k}: expected a font stack`);
  }
  problems.push(...keyProblems("shape", raw.shape, SHAPE_KEYS));
  if (isRecord(raw.shape)) {
    const s = raw.shape;
    problems.push(...inRange("shape.tilt", s.tilt, 0.4, 1));
    problems.push(...inRange("shape.hexLineAlpha", s.hexLineAlpha, 0, 1));
    problems.push(...inRange("shape.paper", s.paper, 0, 1));
    problems.push(...inRange("shape.radius", s.radius, 0, 24));
    if (!TILE_STYLES.includes(s.tileStyle as TileStyle)) problems.push("shape.tileStyle: expected full or inner");
  }
  return problems;
}

export function parseTheme(raw: unknown): Theme {
  const problems = themeProblems(raw);
  if (problems.length > 0) throw new Error(`Invalid theme: ${problems.join("; ")}`);
  return raw as Theme;
}

export function isTileStyle(v: unknown): v is TileStyle {
  return TILE_STYLES.includes(v as TileStyle);
}
