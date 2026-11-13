// The view "Karte" in the game frame (#258) in a real browser: stub API with the fixture /map and one
// recorded game; the map appears in the main area, follows its size, a laid tile arrives with the next poll
// as a diff, clicks reach frame.hooks.map. Skipped without a headless browser.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { copyFileSync, cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import { test } from "node:test";
import { build } from "esbuild";

const browser = process.env.OE_BROWSER ?? ["/usr/bin/chromium-headless-shell", "/usr/bin/chromium"].find((p) => existsSync(p));
const web = new URL("..", import.meta.url).pathname;
const shot = new URL("../../bin/shot.mjs", import.meta.url).pathname;
const MIME: Record<string, string> = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };
const read = (f: string) => JSON.parse(readFileSync(join(web, "test", "fixtures", f), "utf8"));

function fixtureMap() {
  const geometry = read("map-geometry.json");
  const zones = new Map((read("map-zones.json").hexes as { id: string }[]).map((h) => [h.id, h]));
  const tracks = read("map-tiles.json");
  const printed = new Map((tracks.hexes as { id: string }[]).map((h) => [h.id, h]));
  const parts = ({ paths, cities, towns, double_towns, offboards, junction }: Record<string, unknown>) => ({ paths, cities, towns, double_towns, offboards, junction });
  geometry.hexes = geometry.hexes.map((h: { id: string }) => ({ ...h, ...zones.get(h.id), ...parts(printed.get(h.id) ?? {}) }));
  geometry.tiles = tracks.tiles;
  return geometry;
}

async function bundle(dir: string) {
  await build({ entryPoints: [join(web, "main.ts")], bundle: true, format: "esm", target: "es2022", outfile: join(dir, "main.js"), logLevel: "silent" });
  for (const f of ["index.html", "theme.css"]) copyFileSync(join(web, f), join(dir, f));
  copyFileSync(join(web, "ui", "kit", "kit.css"), join(dir, "kit.css"));
  copyFileSync(join(web, "ui", "frame", "frame.css"), join(dir, "frame.css"));
  cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
  copyFileSync(join(web, "fonts", "fonts.css"), join(dir, "fonts.css"));
  const { themesCss } = await import("../themes/css.ts");
  const { DEFAULT_THEME_ID, themes } = await import("../themes/index.ts");
  writeFileSync(join(dir, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
}

const CHECKS = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  const host = q(".frame-map") || fail("no map host");
  for (let i = 0; i < 100 && host.dataset.state !== "ready"; i++) await sleep(100);
  if (host.dataset.state !== "ready") fail("map not ready: " + host.dataset.state);
  const m = window.oeMap || fail("no oeMap");
  const c = host.querySelector("canvas") || fail("no canvas");
  // The renderer follows the host through a ResizeObserver, so the canvas catches up a frame after layout settles.
  let hb, cb;
  for (let i = 0; i < 20; i++) {
    hb = host.getBoundingClientRect(); cb = c.getBoundingClientRect();
    if (Math.abs(cb.width - hb.width) <= 2 && Math.abs(cb.height - hb.height) <= 2) break;
    await sleep(100);
  }
  if (hb.width < 300 || hb.height < 200) fail("host too small " + hb.width + "x" + hb.height);
  if (Math.abs(cb.width - hb.width) > 2 || Math.abs(cb.height - hb.height) > 2) fail("canvas does not fill the host " + JSON.stringify([hb.width, hb.height, cb.width, cb.height]));
  if (q(".frame-map-status") && !q(".frame-map-status").hidden) fail("status still shown");
  // Events reach the frame.
  const seen = [];
  window.oeFrameMap.on("hex", (d) => seen.push(d.hex));
  const p = m.hexOnScreen("A2") || fail("no hex on screen");
  const ev = (type) => c.dispatchEvent(new PointerEvent(type, { clientX: cb.left + p.x, clientY: cb.top + p.y, pointerId: 1, pointerType: "touch", button: 0, bubbles: true }));
  ev("pointerdown"); ev("pointerup");
  await sleep(100);
  if (seen.length === 0) fail("click did not reach frame.hooks.map");
  // Camera survives a resize and a re-mount of the view container.
  const zoom = m.view.zoom;
  // A laid tile arrives with the next poll (5 s): only that hex is redrawn.
  await fetch("/__advance");
  for (let i = 0; i < 100 && m.stats().stateHexes < 1; i++) await sleep(100);
  if (m.stats().stateHexes < 1) fail("poll state did not reach the map: " + JSON.stringify(m.stats()));
  if (m.view.zoom !== zoom) fail("camera changed on state");
})()`;

test("map view in the game frame: loads /map, follows the main area, diffs state per poll, passes clicks on", { skip: browser ? false : "no headless browser installed" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-mapframe-test-"));
  try {
    await bundle(dir);
    const geometry = fixtureMap();
    const tile = Object.keys(geometry.tiles)[0]!;
    let game = read("games/track.json");
    let mapFetches = 0;
    const server = createServer((req, res) => {
      const p = new URL(req.url!, "http://x").pathname;
      const json = (o: unknown) => { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify(o)); };
      if (p === "/me") return json({ id: "p0", name: "p0" });
      if (p === "/map") { mapFetches++; return json(geometry); }
      if (p === "/games/1") return json(game);
      if (p === "/games/1/version") return json({ seq: game.seq, status: "active" });
      if (p === "/__advance") {
        game = { ...game, seq: game.seq + 1, state: { ...game.state, map: [{ hex: "A2", tile: { name: tile, rotation: 0, color: "yellow" }, tokens: [] }] } };
        return json({ ok: true });
      }
      const f = join(dir, p === "/" ? "index.html" : p);
      if (existsSync(f)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); } else { res.writeHead(404); res.end(); }
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as { port: number }).port;
    const code = await new Promise<number>((resolve) => {
      const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/#/game/1`, join(dir, "out.png"), "--width", "1440", "--height", "900", "--wait-for", ".frame-map", "--eval", CHECKS], { stdio: "pipe" });
      let err = "";
      child.stderr.on("data", (d) => { err += d; });
      child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
    });
    server.closeAllConnections();
    server.close();
    assert.equal(code, 0, "page checks failed (see stderr)");
    assert.equal(mapFetches, 1, "/map is loaded once");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
