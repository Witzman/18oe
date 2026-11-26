// The map as a bundle of its own (#613): no server, no panels, data handed in, usable under a content security
// policy without eval (browser add-on, workshop #606).
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { buildStandalone } from "../build-standalone.mjs";
import { boardState, type Board } from "../render/board.ts";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const fixture = (name: string) => join(web, "test", "fixtures", name);

const board: Board = {
  map: [{ hex: "J79", tile: { name: "57", rotation: 1, color: "yellow" }, tokens: [{ city: 0, corporations: ["A"] }] }],
  corporations: [{ id: "A", closed: false, tokens: [{ used: true, hex: "J79" }] }],
  phase_tiles: ["yellow", "green"],
};

test("a board becomes exactly the part of the game state the map reads", () => {
  const state = boardState(board);
  assert.deepEqual(state.map, board.map);
  assert.deepEqual(state.corporations, board.corporations);
  assert.deepEqual(state.meta.phase.tiles, ["yellow", "green"]);
  assert.equal(state.meta.current, null);
});

test("a board without map or companies is refused with a message naming the field", () => {
  assert.throws(() => boardState({ corporations: [], phase_tiles: [] } as unknown as Board), /map/);
  assert.throws(() => boardState({ map: [], phase_tiles: [] } as unknown as Board), /corporations/);
  assert.throws(() => boardState({ map: [], corporations: [] } as unknown as Board), /phase_tiles/);
});

test("the bundle holds the renderer and its themes, no app, server or panel code", async () => {
  const out = mkdtempSync(join(tmpdir(), "oe-standalone-"));
  const boardFile = join(out, "board.json");
  writeFileSync(boardFile, JSON.stringify(board));
  const result = await buildStandalone({ out, geometry: fixture("map-geometry.json"), board: boardFile });

  const outside = result.inputs.filter((file) => !file.startsWith("node_modules/"))
    .filter((file) => !file.startsWith("render/") && !file.startsWith("themes/"));
  // what map.ts takes from the UI (the picker's element builder and texts, the theme change event); a new entry
  // here means the bundle grows into the app: decouple it, or add it on purpose
  assert.deepEqual(outside.sort(), ["ui/dom.ts", "ui/text.ts", "ui/theme-switch.ts"]);
  assert.ok(result.inputs.includes("render/map.ts"));
  assert.ok(result.inputs.some((file) => file.startsWith("node_modules/pixi.js/lib/unsafe-eval/")), "eval-free shader code");
});

test("the test page is one file: bundle, data and fonts inside, a policy without eval and without the network", async () => {
  const out = mkdtempSync(join(tmpdir(), "oe-standalone-"));
  const boardFile = join(out, "board.json");
  writeFileSync(boardFile, JSON.stringify(board));
  await buildStandalone({ out, geometry: fixture("map-geometry.json"), board: boardFile });

  const html = readFileSync(join(out, "map.html"), "utf8");
  const policy = html.match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)![1]!;
  assert.match(policy, /default-src 'none'/);
  assert.doesNotMatch(policy, /unsafe-eval|http/);
  assert.doesNotMatch(html, /<script[^>]+src=|<link[^>]+href=|url\(\/fonts\//);
  assert.match(html, /url\(data:font\/woff2;base64,/);
  assert.ok(html.includes('"phase_tiles":["yellow","green"]'), "the board is embedded");
  // the bundle on its own, for an add-on to load
  assert.ok(readFileSync(join(out, "oe-map.js"), "utf8").includes("OeMap"));
});
