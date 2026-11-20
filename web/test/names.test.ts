// #455: place names on the map (render/names.ts): which hexes carry a label and when it is shown.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { nameLabels, nameVisible } from "../render/names.ts";
import type { MapHex } from "../render/mapdata.ts";

const here = dirname(fileURLToPath(import.meta.url));
const tiles = JSON.parse(readFileSync(join(here, "fixtures", "map-tiles.json"), "utf8"));
const hexes: MapHex[] = tiles.hexes;

test("a label for every named hex that is not a red off-board hex (those carry their name in the revenue box)", () => {
  const labels = nameLabels(hexes);
  const named = hexes.filter((h) => h.name);
  const red = named.filter((h) => h.color === "red");
  assert.ok(red.length > 5 && named.length > 200);
  assert.equal(labels.length, named.length - red.length);
  assert.ok(labels.every((l) => l.name.length > 0 && !red.some((h) => h.id === l.id)));
  assert.ok(labels.some((l) => l.id === "B43" && l.name === "Voss"));
});

test("shown from the name zoom on, or always for the hovered hex", () => {
  assert.equal(nameVisible({ zoom: 30, nameZoom: 24, hovered: false }), true);
  assert.equal(nameVisible({ zoom: 10, nameZoom: 24, hovered: false }), false);
  assert.equal(nameVisible({ zoom: 10, nameZoom: 24, hovered: true }), true);
  assert.equal(nameVisible({ zoom: 24, nameZoom: 24, hovered: false }), true);
});

import { REGION_LABELS, seaLabel } from "../render/names.ts";

test("board names (#461): the eleven regions of the board; a sea name with a bracket becomes two lines under the circle", () => {
  assert.equal(REGION_LABELS.length, 11);
  assert.ok(REGION_LABELS.some((l) => l.lines.join(" ") === "France and Belgium"));
  assert.deepEqual(seaLabel("North Sea", { x: 10, y: 5 }, 1), { lines: ["North Sea"], x: 10, y: 6 });
  assert.deepEqual(seaLabel("North Atlantic (Silver Coast)", { x: 1, y: 2 }, 1).lines, ["North Atlantic", "(Silver Coast)"]);
});
