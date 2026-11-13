// The map in a real browser (#44): bundles main.ts, opens #/map on the fixture map with bin/shot and
// drives the facade from inside the page (clicks, drag, wheel, hover, setState, flyTo, theme change,
// key 0). The page script throws on the first failed check, so bin/shot exits non-zero.
// Skipped without a headless browser (like shot.test.ts).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { build } from "esbuild";

const browser = process.env.OE_BROWSER ?? ["/usr/bin/chromium-headless-shell", "/usr/bin/chromium"].find((p) => existsSync(p));
const web = new URL("..", import.meta.url).pathname;
const shot = new URL("../../bin/shot.mjs", import.meta.url).pathname;

function fixtureMap(): string {
  const read = (f: string) => JSON.parse(readFileSync(join(web, "test", "fixtures", f), "utf8"));
  const geometry = read("map-geometry.json");
  const zones = new Map((read("map-zones.json").hexes as { id: string }[]).map((h) => [h.id, h]));
  // Track parts (#146): printed track per hex and the tile catalog, from the #144 excerpt of GET /map.
  const tracks = read("map-tiles.json");
  const printed = new Map((tracks.hexes as { id: string }[]).map((h) => [h.id, h]));
  const parts = ({ paths, cities, towns, double_towns, offboards, junction }: Record<string, unknown>) => ({ paths, cities, towns, double_towns, offboards, junction });
  geometry.hexes = geometry.hexes.map((h: { id: string }) => ({ ...h, ...zones.get(h.id), ...parts(printed.get(h.id) ?? {}) }));
  geometry.tiles = tracks.tiles;
  return JSON.stringify(geometry);
}

// Runs inside the page. Every check throws with a message.
const CHECKS = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const m = window.oeMap || fail("no window.oeMap");
  const c = document.querySelector("canvas") || fail("no canvas");
  const box = c.getBoundingClientRect();
  const ev = (type, p, extra = {}) => c.dispatchEvent(new PointerEvent(type, { clientX: box.left + p.x, clientY: box.top + p.y, pointerId: 1, pointerType: "mouse", button: 0, bubbles: true, ...extra }));
  const st = m.stats();
  if (!(st.blocks > 100 && st.visibleBlocks > 0 && st.buildMs > 0)) fail("stats " + JSON.stringify(st));
  if (m.layer("tiles").children.length === 0) fail("no level containers");

  // Clicks at pitch 0: the centre of every visible hex reports that hex.
  let clicked = null;
  m.on("hex", (d) => { clicked = d.hex; });
  let n = 0;
  for (const h of m.scene.grid.hexes) {
    const p = m.hexOnScreen(h.id);
    if (p.x < 2 || p.y < 2 || p.x > box.width - 2 || p.y > box.height - 2) continue;
    clicked = null;
    ev("pointerdown", p); ev("pointerup", p);
    if (clicked !== h.id) fail("click on " + h.id + " gave " + clicked);
    n++;
  }
  if (n < 1400) fail("only " + n + " hexes clicked");

  // Hover reports the hex under the pointer, and null on leave.
  let hovered = "unset";
  m.on("hover", (d) => { hovered = d.hex; });
  ev("pointermove", m.hexOnScreen("Q30"));
  if (hovered !== "Q30") fail("hover " + hovered);
  c.dispatchEvent(new PointerEvent("pointerleave", { pointerId: 1 }));
  if (hovered !== null) fail("hover after leave " + hovered);

  // Drag pans and is not a click.
  const v0 = m.view;
  clicked = null;
  ev("pointerdown", { x: 700, y: 400 }); ev("pointermove", { x: 730, y: 415 }); ev("pointermove", { x: 760, y: 430 }); ev("pointerup", { x: 760, y: 430 });
  if (clicked !== null) fail("drag clicked " + clicked);
  if (Math.abs(m.view.panX - v0.panX - 60) > 1e-6 || Math.abs(m.view.panY - v0.panY - 30) > 1e-6) fail("drag pan " + JSON.stringify([v0, m.view]));

  // Wheel zooms about the pointer: the hex under it stays.
  const at = m.hexOnScreen("R55");
  c.dispatchEvent(new WheelEvent("wheel", { deltaY: -300, clientX: box.left + at.x, clientY: box.top + at.y, bubbles: true, cancelable: true }));
  if (!(m.view.zoom > v0.zoom * 1.4)) fail("wheel zoom " + m.view.zoom);
  clicked = null; ev("pointerdown", at); ev("pointerup", at);
  if (clicked !== "R55") fail("after zoom the pointer is over " + clicked);

  // setState redraws only changed hexes, except that a change in the set or colour of the raised
  // (tiled) hexes rebuilds the scene (heights, levels and walls: #145), reported as every hex.
  const game = (map) => ({ meta: { current: null }, corporations: [], map });
  const t = (hex, name, color, rotation = 0) => ({ hex, tile: { name, rotation, color } });
  m.setState(game([t("Q30", "57", "yellow"), t("R55", "57", "yellow")]));
  if (m.stats().stateHexes !== 1492) fail("first state " + m.stats().stateHexes);
  const lvl = m.scene.levels.length;
  if (!m.scene.tiled.has("Q30")) fail("Q30 not raised by its tile");
  m.setState(game([t("Q30", "57", "yellow")]));
  m.setState(game([t("Q30", "57", "yellow"), t("R55", "57", "yellow")]));
  m.setState(game([t("Q30", "57", "yellow"), t("R55", "57", "yellow")]));
  if (m.stats().stateHexes !== 0) fail("same state " + m.stats().stateHexes);
  m.setState(game([t("Q30", "57", "yellow"), t("R55", "15", "green", 2)]));
  if (m.stats().stateHexes !== 1492) fail("colour change rebuilds " + m.stats().stateHexes);
  if (m.scene.levels.length < lvl) fail("levels lost");
  m.setState(game([t("Q30", "57", "yellow"), t("R55", "15", "green", 3)]));
  if (m.stats().stateHexes !== 1) fail("one change " + m.stats().stateHexes);
  await m.rendered();
  if (!(m.stats().stateMs >= 0)) fail("stateMs");

  // Track (#146): printed hexes and the laid tile R55 carry a "track" container with the four parts;
  // the zoom stage only toggles their visibility.
  const tracks = [];
  const walk = (n) => { if (n.label === "track") tracks.push(n); n.children?.forEach(walk); };
  walk(m.layer("tiles"));
  if (tracks.length < 50) fail("only " + tracks.length + " track containers");
  if (tracks.some((n) => n.children.length !== 4)) fail("a track container without its four parts");
  const stageVisible = () => tracks.map((n) => n.children.map((g) => g.visible ? 1 : 0).join(""));
  await m.rendered();
  const stages = new Set(stageVisible());
  if (stages.size !== 1) fail("track parts differ between hexes: " + [...stages]);
  m.setTargets({ kind: "tile", hexes: ["Q30", "S42"] });

  // flyTo a hex and a corporation home; unknown targets are refused.
  if (m.flyTo("NOPE")) fail("flyTo unknown");
  if (!m.flyTo("S42")) fail("flyTo S42");
  await sleep(1200); await m.rendered();
  clicked = null; ev("pointerdown", { x: box.width / 2, y: box.height / 2 }); ev("pointerup", { x: box.width / 2, y: box.height / 2 });
  if (clicked !== "S42") fail("after flyTo the centre is " + clicked);

  // Key 0 shows the whole map again.
  c.parentElement.dispatchEvent(new KeyboardEvent("keydown", { key: "0", bubbles: true }));
  await sleep(1200); await m.rendered();
  const all = m.scene.grid.hexes.every((h) => { const p = m.hexOnScreen(h.id); return p.x > -1 && p.y > -30 && p.x < box.width + 1 && p.y < box.height + 1; });
  if (!all) fail("key 0 does not show the whole map");

  // Cities and tokens (#147): Q30 has three one-slot cities; a token in city 0 and one in city 1 stand in the
  // objects layer, a click on a token reports "city" with its slot (and "hex" as well), a click beside it only "hex".
  m.setState({ meta: { current: null }, corporations: [{ id: "PLM", closed: false, floated: true, tokens: [] }, { id: "KK", closed: false, floated: true, tokens: [] }],
    map: [{ hex: "Q30", tile: { name: "x", rotation: 0, color: "yellow" }, tokens: [{ city: 0, corporations: ["PLM"] }, { city: 1, corporations: ["KK"] }] }] });
  if (m.layer("objects").children.length !== 2) fail("tokens in the objects layer: " + m.layer("objects").children.length);
  m.flyTo("Q30");
  await sleep(1200); await m.rendered();
  const toks = m.layer("objects").children.filter((k) => k.visible);
  if (toks.length !== 2) fail("visible tokens " + toks.length);
  const cityEv = []; const hexEv = [];
  m.on("city", (d) => cityEv.push(d)); m.on("hex", (d) => hexEv.push(d));
  const foot = toks[0].position;
  ev("pointerdown", { x: foot.x, y: foot.y }); ev("pointerup", { x: foot.x, y: foot.y });
  if (cityEv.length !== 1 || cityEv[0].hex !== "Q30" || cityEv[0].slot !== 0 || (cityEv[0].city !== 0 && cityEv[0].city !== 1)) fail("city click " + JSON.stringify(cityEv));
  if (hexEv.length !== 1 || hexEv[0].hex !== "Q30") fail("hex click with the city " + JSON.stringify(hexEv));
  const far = { x: foot.x + 120, y: foot.y + 120 };
  ev("pointerdown", far); ev("pointerup", far);
  if (cityEv.length !== 1) fail("a click away from the slots reported a city");

  // Theme change rebuilds with the new theme's heights.
  document.documentElement.dataset.theme = "atlas";
  document.dispatchEvent(new CustomEvent("oe:themechange"));
  await m.rendered(); await m.rendered();
  if (Math.abs(m.scene.levels[1] - 0.06) > 1e-9) fail("atlas heightLand not applied: " + m.scene.levels);
  if (!(m.stats().themeMs > 0)) fail("themeMs " + m.stats().themeMs);
  return JSON.stringify(m.stats());
})()`;

test("the map facade works in a browser: click, hover, drag, wheel, setState, flyTo, key 0, theme change", { skip: browser ? false : "no headless browser installed", timeout: 120000 }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-map-test-"));
  try {
    await build({ entryPoints: [join(web, "main.ts")], bundle: true, format: "esm", target: "es2022", outfile: join(dir, "main.js"), logLevel: "silent" });
    copyFileSync(join(web, "index.html"), join(dir, "index.html"));
    copyFileSync(join(web, "theme.css"), join(dir, "theme.css"));
    writeFileSync(join(dir, "map.json"), fixtureMap());
    const out = join(dir, "out.png");
    const r = spawnSync(process.execPath, [shot, `${join(dir, "index.html")}#/map?src=/map.json&pitch=0&yaw=0`, out,
      "--width", "1280", "--height", "800", "--wait-for", ".map-dev[data-ready]", "--eval", CHECKS, "--delay", "0"], { encoding: "utf8", timeout: 110000 });
    assert.equal(r.status, 0, r.stderr + r.stdout);
    assert.doesNotMatch(r.stderr, /page error/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
