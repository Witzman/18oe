// Track panel (#48) and token panel (#174) in a real browser: stub API with the fixture /map and a recorded
// state (track-lay, token-place). A tap on a glowing hex picks it, the map shows the preview, the tile and
// rotation buttons change it, nothing is sent before the main button, then exactly the offered action is sent.
// Same stub-server approach as map-frame-browser.test.ts. Skipped without a headless browser (CI job "browser").
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
  for (const f of ["stock.css", "train.css", "track.css"]) copyFileSync(join(web, "ui", "panels", f), join(dir, f));
  cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
  copyFileSync(join(web, "fonts", "fonts.css"), join(dir, "fonts.css"));
  const { themesCss } = await import("../themes/css.ts");
  const { DEFAULT_THEME_ID, themes } = await import("../themes/index.ts");
  writeFileSync(join(dir, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
}

const HEAD = String.raw`const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  const small = (sel) => { for (const e of document.querySelectorAll(sel)) { const r = e.getBoundingClientRect(); if (r.height < 43.5 || r.width < 43.5) fail(sel + " too small: " + r.width + "x" + r.height); } };
  const posted = async () => (await fetch("/__posted")).json();
  const host = q(".frame-map") || fail("no map host");
  for (let i = 0; i < 150 && host.dataset.state !== "ready"; i++) await sleep(100);
  if (host.dataset.state !== "ready") fail("map not ready: " + host.dataset.state);
  const m = window.oeMap || fail("no oeMap");
  const c = host.querySelector("canvas") || fail("no canvas");
  await sleep(300);
  const findLabel = (node, label) => node.label === label || (node.children || []).some((k) => findLabel(k, label));
  const tap = async (hex, type) => {
    await m.rendered();
    const cb = c.getBoundingClientRect();
    const p = m.hexOnScreen(hex) || fail("no hex on screen " + hex);
    const ev = (t) => c.dispatchEvent(new PointerEvent(t, { clientX: cb.left + p.x, clientY: cb.top + p.y, pointerId: 7, pointerType: type, button: 0, bubbles: true }));
    ev("pointerdown"); ev("pointerup");
    await sleep(150);
    await m.rendered();
  };
  const tab = () => q('.frame-tabs [aria-selected="true"]')?.textContent;`;

const TRACK = String.raw`(async () => {
  ${HEAD}
  if (document.querySelectorAll(".track-hex").length !== 2) fail("hex rows " + document.querySelectorAll(".track-hex").length);
  small(".track-hex"); small(".track-map");
  if (q(".frame-entry")) fail("generic bar still offers the claimed actions");
  if (q(".kit-main-btn") && !q(".kit-main-btn").disabled) fail("main button open before a pick");
  if (findLabel(m.layer("overlay"), "preview I86")) fail("preview before a pick");
  // Tap I86 on the map: picked, first tile previewed on the map.
  await tap("I86", "mouse");
  if (q('.track-hex[data-hex="I86"]')?.getAttribute("aria-pressed") !== "true") fail("map tap did not pick I86");
  if (!findLabel(m.layer("overlay"), "preview I86")) fail("no preview on the map");
  if (document.querySelectorAll(".track-tile svg").length !== 3) fail("tiles not drawn");
  small(".track-tile"); small(".track-turn"); small(".kit-main-btn");
  // Another tile, then tap the same hex again: the rotation turns.
  q('.track-tile[data-tile="8-8"]').click();
  await sleep(100);
  if (!/Drehung 1 von 2/.test(q(".track-rotation").textContent)) fail("rotation label " + q(".track-rotation").textContent);
  await tap("I86", "touch");
  if (!/Drehung 2 von 2/.test(q(".track-rotation").textContent)) fail("second tap did not turn: " + q(".track-rotation").textContent);
  if (!/M legt Kachel 8 auf I86, Drehung 2 von 2/.test(q(".kit-order-sentence").textContent)) fail("sentence: " + q(".kit-order-sentence").textContent);
  // The way back to the map from another view.
  const other = [...document.querySelectorAll(".frame-tabs [role=tab]")].find((b) => b.getAttribute("aria-selected") !== "true");
  if (other) { other.click(); await sleep(100); q(".track-map").click(); await sleep(100); if (tab() !== "Karte") fail("no way back to the map: " + tab()); }
  if ((await posted()).length !== 0) fail("previewing sent something");
  q(".kit-main-btn").click();
  await sleep(600);
  if ((await posted()).length !== 1) fail("not sent once");
})()`;

const TOKEN = String.raw`(async () => {
  ${HEAD}
  if (document.querySelectorAll(".token-city").length !== 2) fail("city rows");
  small(".token-city");
  if (q(".frame-entry")) fail("generic bar still offers the claimed actions");
  await tap("Y14", "touch");
  if (q('.token-city[data-city="OE4-2-1"]')?.getAttribute("aria-pressed") !== "true") fail("map tap did not pick Y14");
  if (!findLabel(m.layer("overlay"), "preview Y14")) fail("no token preview on the map");
  if (!/G setzt eine Station in Y14/.test(q(".kit-order-sentence").textContent)) fail("sentence: " + q(".kit-order-sentence").textContent);
  q('.token-city[data-city="57-7-0"]').click();
  await sleep(150);
  if (!findLabel(m.layer("overlay"), "preview AC16")) fail("row pick did not move the preview");
  if ((await posted()).length !== 0) fail("previewing sent something");
  q(".kit-main-btn").click();
  await sleep(600);
  if ((await posted()).length !== 1) fail("not sent once");
})()`;

async function scenario(name: string, waitFor: string, checks: string) {
  const dir = mkdtempSync(join(tmpdir(), "oe-track-test-"));
  try {
    await bundle(dir);
    const geometry = fixtureMap();
    let game = read(`games/${name}.json`);
    const start = game;
    const posted: { action: Record<string, unknown>; seq: number }[] = [];
    const server = createServer((req, res) => {
      const p = new URL(req.url!, "http://x").pathname;
      const json = (o: unknown) => { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify(o)); };
      if (p === "/me") return json({ id: start.viewer, name: start.viewer });
      if (p === "/map") return json(geometry);
      if (p === "/games/1") return json(game);
      if (p === "/games/1/version") return json({ seq: game.seq, status: "active" });
      if (p === "/__posted") return json(posted);
      if (p === "/games/1/actions" && req.method === "POST") {
        let b = "";
        req.on("data", (d) => { b += d; });
        req.on("end", () => { posted.push(JSON.parse(b)); game = { ...game, seq: game.seq + 1 }; json(game); });
        return;
      }
      const f = join(dir, p === "/" ? "index.html" : p);
      if (existsSync(f)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); } else { res.writeHead(404); res.end(); }
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as { port: number }).port;
    const code = await new Promise<number>((resolve) => {
      const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/#/game/1`, join(dir, "out.png"), "--width", "1440", "--height", "900", "--wait-for", waitFor, ...(process.env.OE_THEME ? ["--theme", process.env.OE_THEME] : []), "--eval", checks], { stdio: "pipe" });
      let err = "";
      child.stderr.on("data", (d) => { err += d; });
      child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
    });
    if (process.env.OE_SHOT_DIR) copyFileSync(join(dir, "out.png"), join(process.env.OE_SHOT_DIR, `${name}-${process.env.OE_THEME ?? "default"}.png`));
    server.closeAllConnections();
    server.close();
    assert.equal(code, 0, "page checks failed (see stderr)");
    return { posted, game: start };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test("track in the browser: tap a hex, pick a tile, tap again to turn, map preview, confirm sends the offered lay_tile", { skip: browser ? false : "no headless browser installed" }, async () => {
  const { posted, game } = await scenario("track-lay", ".track-hex", TRACK);
  assert.equal(posted.length, 1);
  const want = game.state.prompt.actions.find((a: Record<string, unknown>) => a.type === "lay_tile" && a.hex === "I86" && a.tile === "8-8" && a.rotation === 3);
  assert.ok(want, "fixture offers I86 8-8 rotation 3");
  assert.deepEqual(posted[0]!.action, want);
  assert.equal(posted[0]!.seq, game.seq);
});

test("token in the browser: tap a city on the map, preview on the slot, pick by row, confirm sends the offered place_token", { skip: browser ? false : "no headless browser installed" }, async () => {
  const { posted, game } = await scenario("token-place", ".token-city", TOKEN);
  assert.equal(posted.length, 1);
  assert.deepEqual(posted[0]!.action, game.state.prompt.actions.find((a: Record<string, unknown>) => a.city === "57-7-0"));
  assert.equal(posted[0]!.seq, game.seq);
});
