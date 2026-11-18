// #452: the ferry lines of the map, found from `ports` and the paths of the sea hexes (render/ferries.ts), against the 21
// ferry components the engine builds (Game#ferry_components: hexes of the blue lines, distance, the land ends).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { findFerries } from "../render/ferries.ts";
import type { MapHex } from "../render/mapdata.ts";

const here = dirname(fileURLToPath(import.meta.url));
const read = (f: string) => JSON.parse(readFileSync(join(here, "fixtures", f), "utf8"));
const geometry = read("map-geometry.json");
const tiles = new Map<string, Partial<MapHex>>(read("map-tiles.json").hexes.map((h: MapHex) => [h.id, h]));
const hexes: MapHex[] = geometry.hexes.map((h: MapHex) => ({ ...h, ...(tiles.get(h.id) ?? {}) }));

// [distance, hexes of the line, ends as hex:side], from the engine (Game#ferry_components, 18oe main of 2026-11-18)
const ENGINE: [number, string, string][] = [
  [0, "AA26", "AB27:2 Z27:0"], [0, "AA40", "Z41:0 AB39:3"], [0, "AE12 AF13", "AD13:0 AF11:4"], [0, "AE54", "AF53:3 AD55:0"],
  [0, "AE6", "AD7:0 AF5:3"], [0, "G22", "H21:3 G24:1"], [0, "N29", "M28:5 N31:1"], [0, "Y38 Y40", "X37:5 Z41:2"],
  [1, "A58 A60 A62", "A56:4 A64:1"], [1, "AA42 AA44 AA46", "AB41:3 Z47:0"], [1, "AB21 AB23 AB25", "AA20:5 AB27:1"],
  [1, "AB59 AB61 AC62 AD63 AE64 AE66", "AB57:4 AE68:1"], [1, "AC26 AD27 AE26", "AB27:0 AF25:3"],
  [1, "AD75 AD77 AE74 AF73", "AE72:5 AD79:1"], [1, "AG42 AG44 AG46 AG48", "AG40:4 AF49:0 AG50:1"], [1, "C62 D59 D61", "D57:4 C64:1"],
  [1, "B39 C38 D37 E36 F35 G30 G32 G34", "G26:offshore B41:1"], [1, "I22 I24", "I20:4 J23:2 J25:2 I26:1"],
  [1, "H57 I58 J59", "H55:4 K60:2"], [1, "N25", "M26:0 O24:3"], [1, "X79 Y80 Z81", "AA82:2 X79:5"],
];
const sorted = (s: string) => s.split(" ").sort().join(" ");

test("the 21 ferries of the map are found, with the hexes of their line, distance and ends of the engine", () => {
  const found = findFerries(hexes, geometry.ports);
  assert.equal(found.length, 21);
  const mine = found.map((f) => [f.distance, sorted([...new Set(f.paths.map((k) => k.split("#")[0]!))].join(" ")), sorted(f.ends.map((e) => `${e.hex}:${e.edge}`).join(" "))]);
  const theirs = ENGINE.map(([d, h, e]) => [d, sorted(h), sorted(e)]);
  assert.deepEqual(mine.sort(), theirs.sort());
});

test("every ferry carries its oval on one of its own paths, the middle one", () => {
  for (const f of findFerries(hexes, geometry.ports)) {
    assert.ok(f.paths.includes(f.label), `the oval of ${f.paths[0]} is on its line`);
    assert.equal(f.paths.indexOf(f.label), Math.floor(f.paths.length / 2));
  }
});

test("no paths without ports, and a ferry end on land only without a sea hex across the side finds nothing", () => {
  assert.deepEqual(findFerries(hexes, undefined), []);
  assert.deepEqual(findFerries(hexes, [{ hex: "L37", edge: 5, ferries: [{ hex: "X", exit: 0, distance: 1 }] }]), [], "Amsterdam's side 5 leads to a sea hex without a line");
});

test("a ferry line is never found twice: its paths belong to one ferry only", () => {
  const seen = new Set<string>();
  for (const f of findFerries(hexes, geometry.ports)) for (const p of f.paths) { assert.ok(!seen.has(p), `${p} twice`); seen.add(p); }
});
