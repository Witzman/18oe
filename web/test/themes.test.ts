import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { currentRenderTheme, renderTheme } from "../render/theme.ts";
import { applyChoice, choiceFromRoot, loadChoice, saveTheme, saveTileStyle, THEME_KEY, TILE_STYLE_KEY, type KeyValue } from "../themes/choice.ts";
import { contrast, hexToNumber } from "../themes/color.ts";
import { cssVar, themesCss, themeVars } from "../themes/css.ts";
import { DEFAULT_THEME_ID, themeById, themes } from "../themes/index.ts";
import { CAMERA_KEYS, COLOR_KEYS, FONT_KEYS, migrateTheme, MOTION_KEYS, NUMBER_RANGES, parseTheme, SHAPE_KEYS, themeProblems, TILE_COLOR_KEYS, TOP_KEYS, TRACK_KEYS, type ColorGroup } from "../themes/schema.ts";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "themes");
const files = readdirSync(dir).filter((f) => f.endsWith(".json"));
const raw = (f: string) => JSON.parse(readFileSync(join(dir, f), "utf8")) as Record<string, Record<string, unknown>>;

function memory(initial: Record<string, string> = {}): KeyValue & { data: Record<string, string> } {
  const data = { ...initial };
  return {
    data,
    getItem: (k) => data[k] ?? null,
    setItem: (k, v) => { data[k] = v; },
    removeItem: (k) => { delete data[k]; },
  };
}

test("ships the themes Brett and Atlas, Brett is the default", () => {
  assert.deepEqual(themes.map((t) => t.id).sort(), ["atlas", "brett"]);
  assert.equal(DEFAULT_THEME_ID, "brett");
  assert.equal(themeById(null).id, "brett");
  assert.equal(themeById("no-such-theme").id, "brett");
});

test("every theme file is listed and its id matches its file name", () => {
  assert.deepEqual(files.map((f) => f.replace(".json", "")).sort(), themes.map((t) => t.id).sort());
  for (const f of files) assert.equal(raw(f).id, f.replace(".json", ""));
});

for (const file of files) {
  test(`${file} has exactly the token keys of the schema`, () => {
    const t = raw(file);
    assert.deepEqual(themeProblems(t), []);
    assert.deepEqual(Object.keys(t).sort(), [...TOP_KEYS].sort());
    for (const group of Object.keys(COLOR_KEYS) as ColorGroup[]) {
      assert.deepEqual(Object.keys(t[group]!).sort(), [...COLOR_KEYS[group]].sort(), group);
    }
    assert.deepEqual(Object.keys(t.font!).sort(), [...FONT_KEYS].sort());
    assert.deepEqual(Object.keys(t.shape!).sort(), [...SHAPE_KEYS].sort());
    assert.deepEqual(Object.keys(t.camera!).sort(), [...CAMERA_KEYS].sort());
    assert.deepEqual(Object.keys(t.track!).sort(), [...TRACK_KEYS].sort());
    assert.deepEqual(Object.keys(t.motion!).sort(), [...MOTION_KEYS].sort());
  });
}

test("a theme with a missing, an unknown or a malformed token is rejected", () => {
  const broken = raw("brett.json");
  delete broken.ui!.ink;
  broken.map!.lava = "#ff0000";
  broken.map!.track = "green";
  broken.shape!.tileStyle = "diagonal";
  assert.deepEqual(themeProblems(broken).sort(), [
    "map.lava: unknown key", "map.track: expected a colour like #1a2b3c",
    "shape.tileStyle: expected full or inner", "ui.ink: missing",
  ].sort());
  assert.ok(themeProblems(null).length > 0);
});

// Owner decisions (#11): half-3D camera, full-hex tiles, track neutral (company colour only on
// tokens, trains, runs and seals).
for (const t of themes) {
  test(`${t.id}: half-3D camera, neutral track and full-hex tiles by default`, () => {
    assert.ok(t.camera.pitch > 0 && t.camera.pitch <= 65);
    assert.equal(t.track.colorMode, "neutral");
    assert.equal(t.shape.tileStyle, "full");
  });

  test(`${t.id}: every number is inside its range`, () => {
    for (const [group, ranges] of Object.entries(NUMBER_RANGES)) {
      const values = t[group as keyof typeof NUMBER_RANGES] as unknown as Record<string, number>;
      for (const [k, [min, max]] of Object.entries(ranges)) assert.ok(values[k]! >= min && values[k]! <= max, `${group}.${k}`);
    }
  });

  test(`${t.id}: text and marks reach their contrast on the surface they sit on`, () => {
    const pairs: [what: string, fg: string, bg: string, min: number][] = [
      ["text on panel", t.ui.ink, t.ui.panel, 7],
      ["secondary text on panel", t.ui.faint, t.ui.panel, 4.5],
      ["error text on panel", t.ui.error, t.ui.panel, 4.5],
      ["text on round bar", t.ui.barInk, t.ui.bar, 7],
      ["text on accent", t.ui.accentInk, t.ui.accent, 4.5],
      ["pressed button (panel on ink)", t.ui.panel, t.ui.ink, 7],
      // Graphics need 3:1 (WCAG 1.4.11).
      ["track on yellow tile", t.map.track, t.map.tileYellow, 3],
      ["label on its halo", t.map.label, t.map.labelHalo, 7],
      ["warn text on panel", t.ui.warn, t.ui.panel, 4.5],
      ["ok text on panel", t.ui.ok, t.ui.panel, 4.5],
      ["info text on panel", t.ui.info, t.ui.panel, 4.5],
      ["text on zebra row", t.ui.ink, t.ui.panelAlt, 7],
      ["track on land", t.map.track, t.map.land, 3],
      ["city outline on city", t.map.cityEdge, t.map.city, 3],
      ["city outline on land", t.map.cityEdge, t.map.land, 3],
      ...TILE_COLOR_KEYS.map((k) => [`rail on ${k}`, t.map.rail, t.map[k], 3] as [string, string, string, number]),
      ["panel edge against page", t.ui.panel, t.ui.bg, 1.1],
    ];
    for (const [what, fg, bg, min] of pairs) {
      const c = contrast(fg, bg);
      assert.ok(c >= min, `${t.id}: ${what} is ${c.toFixed(2)}:1, needs ${min}:1 (${fg} on ${bg})`);
    }
  });

  test(`${t.id}: sea, land and laid tile are distinct areas`, () => {
    assert.ok(contrast(t.map.tileYellow, t.map.land) >= 1.5);
    assert.notEqual(t.map.seaDeep, t.map.land);
    assert.notEqual(t.map.landHigh, t.map.land);
  });
}

test("contrast follows WCAG", () => {
  assert.equal(contrast("#000000", "#ffffff"), 21);
  assert.equal(contrast("#777777", "#777777"), 1);
  assert.equal(hexToNumber("#0a0b0c"), 0x0a0b0c);
  assert.throws(() => hexToNumber("red"));
});

test("the generated CSS carries every token of every theme", () => {
  const css = themesCss(themes, DEFAULT_THEME_ID);
  assert.match(css, /:root, :root\[data-theme="brett"\] \{/);
  assert.match(css, /\n:root\[data-theme="atlas"\] \{/);
  assert.equal(cssVar("map", "seaDeep"), "--map-sea-deep");
  for (const t of themes) {
    const vars = themeVars(t);
    const colours = Object.values(COLOR_KEYS).reduce((n, keys) => n + keys.length, 0);
    const numbers = CAMERA_KEYS.length + TRACK_KEYS.length + MOTION_KEYS.length + SHAPE_KEYS.length - 1; // tileStyle is a data attribute
    assert.equal(vars.length, colours + FONT_KEYS.length + numbers);
    for (const [name, value] of vars) assert.ok(css.includes(`  ${name}: ${value};`), `${t.id} ${name}`);
  }
});

test("theme.css uses only variables that the themes define, and no fixed colours", () => {
  const css = readFileSync(join(dir, "..", "theme.css"), "utf8");
  const defined = new Set(themeVars(themeById("brett")).map(([name]) => name));
  for (const m of css.matchAll(/(--[a-z0-9-]+)\s*:/g)) defined.add(m[1]!); // local helpers (animation timing), built from theme vars
  const used = [...css.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]!);
  assert.ok(used.length > 10);
  assert.deepEqual([...new Set(used)].filter((v) => !defined.has(v)), []);
  assert.deepEqual(css.match(/#[0-9a-f]{3,8}\b|rgba?\(/gi) ?? [], []);
});

test("the renderer palette is the same values as the theme file", () => {
  for (const t of themes) {
    const r = renderTheme({ theme: t, tileStyle: t.shape.tileStyle });
    for (const group of Object.keys(COLOR_KEYS) as ColorGroup[]) {
      const colors: Record<string, string> = t[group];
      const numbers: Record<string, number> = r[group];
      for (const key of COLOR_KEYS[group]) assert.equal(numbers[key], hexToNumber(colors[key]!), `${t.id} ${group}.${key}`);
    }
    assert.deepEqual([r.camera, r.track, r.motion], [t.camera, t.track, t.motion]);
    assert.deepEqual([r.barHeight, r.sideWidth, r.gap], [t.shape.barHeight, t.shape.sideWidth, t.shape.gap]);
    assert.equal(r.hexLineAlpha, t.shape.hexLineAlpha);
  }
});

test("the choice persists, falls back to the default and tolerates broken storage", () => {
  const store = memory();
  assert.equal(loadChoice(store).theme.id, "brett");
  assert.equal(loadChoice(store).tileStyle, "full");

  saveTheme(store, "atlas");
  saveTileStyle(store, "inner");
  assert.deepEqual(store.data, { [THEME_KEY]: "atlas", [TILE_STYLE_KEY]: "inner" });
  const choice = loadChoice(store);
  assert.deepEqual([choice.theme.id, choice.tileStyle, choice.tileStyleOverridden], ["atlas", "inner", true]);

  saveTileStyle(store, null);
  assert.deepEqual([loadChoice(store).tileStyle, loadChoice(store).tileStyleOverridden], ["full", false]);

  assert.equal(loadChoice(memory({ [THEME_KEY]: "gone", [TILE_STYLE_KEY]: "zigzag" })).theme.id, "brett");
  assert.equal(loadChoice(memory({ [TILE_STYLE_KEY]: "zigzag" })).tileStyle, "full");
  saveTheme(store, "gone");
  assert.equal(store.data[THEME_KEY], "brett");

  const broken: KeyValue = {
    getItem: () => { throw new Error("denied"); },
    setItem: () => { throw new Error("denied"); },
    removeItem: () => { throw new Error("denied"); },
  };
  assert.equal(loadChoice(broken).theme.id, "brett");
  assert.doesNotThrow(() => { saveTheme(broken, "atlas"); saveTileStyle(broken, "inner"); saveTileStyle(broken, null); });
  assert.equal(loadChoice(null).theme.id, "brett");
});

test("the choice goes onto the root element and the renderer reads it back from there", () => {
  const root = { dataset: {} as Record<string, string | undefined> };
  assert.equal(currentRenderTheme(root).id, "brett");
  applyChoice(root, loadChoice(memory({ [THEME_KEY]: "atlas", [TILE_STYLE_KEY]: "inner" })));
  assert.deepEqual(root.dataset, { theme: "atlas", tileStyle: "inner" });
  assert.equal(choiceFromRoot(root).tileStyleOverridden, true);
  const r = currentRenderTheme(root);
  assert.deepEqual([r.id, r.tileStyle, r.map.track], ["atlas", "inner", 0x6b2f26]);
});

test("the CSS carries camera, track, motion and panel metrics with their units", () => {
  const vars = Object.fromEntries(themeVars(themeById("brett")));
  assert.equal(vars["--camera-pitch"], "38");
  assert.equal(vars["--camera-light-azimuth"], "315");
  assert.equal(vars["--track-color-mode"], "neutral");
  assert.equal(vars["--motion-enabled"], "1");
  assert.equal(vars["--motion-run-ms-per-hex"], "220");
  assert.equal(vars["--shape-side-width"], "340px");
  assert.equal(vars["--map-tile-yellow"], themeById("brett").map.tileYellow);
  assert.ok(!("--shape-tilt" in vars) && !("--map-tile" in vars));
});

test("out-of-range and inconsistent v2 values are rejected", () => {
  const t = JSON.parse(readFileSync(join(dir, "brett.json"), "utf8")) as Record<string, Record<string, unknown>>;
  t.camera!.pitch = 70;
  t.camera!.yaw = -46;
  t.track!.colorMode = "byBuilder";
  t.track!.sleeperLength = 0.1;
  t.motion!.enabled = "yes";
  t.motion!.queueMaxMs = 1000;
  t.shape!.gap = 40;
  t.shape!.shadow = "";
  assert.deepEqual(themeProblems(t).sort(), [
    "camera.pitch: expected a number from 0 to 65", "camera.yaw: expected a number from -45 to 45",
    "motion.enabled: expected true or false", "motion.queueMaxMs: shorter than runMaxMs",
    "shape.gap: expected a number from 4 to 24", "shape.shadow: expected a CSS box-shadow",
    "track.colorMode: expected builder, neutral or lastRun",
    "track.sleeperLength: shorter than gauge + railWidth",
  ].sort());
});

test("a v1 theme migrates: tilt becomes camera.pitch via acos, tile becomes the five tile colours", () => {
  const v1 = { map: { tile: "#d3e03a", track: "#143d1e" }, shape: { tilt: 0.55, tileStyle: "full" } };
  const m = migrateTheme(v1) as { map: Record<string, string>; shape: Record<string, unknown>; camera: { pitch: number } };
  assert.ok(Math.abs(m.camera.pitch - 56.6) < 0.05);
  assert.ok(!("tilt" in m.shape) && !("tile" in m.map));
  for (const k of TILE_COLOR_KEYS) assert.equal(m.map[k], "#d3e03a");
  assert.equal((migrateTheme({ shape: { tilt: 1 } }) as { camera: { pitch: number } }).camera.pitch, 0);
  assert.ok("tilt" in v1.shape, "input is not modified");
  // A migrated v1 file is still incomplete: the new tokens must come from the author.
  assert.ok(themeProblems(migrateTheme(v1)).includes("camera.yaw: missing"));
  assert.throws(() => parseTheme(v1));
});
