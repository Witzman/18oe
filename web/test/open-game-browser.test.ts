// #294: opening a game whose first state fails. Before, a state that could not be drawn (or a failed load)
// left "Keine Verbindung, neuer Versuch" for a moment and then a page with only the map. Now the band names
// the real reason (HTTP status, request, time, or the display error), keeps its retry button until a state
// is drawn, and the context sheet says the state is still loading. Real page (main.ts bundle) against a stub
// server; skipped without a headless browser.
import assert from "node:assert/strict";
import { copyFileSync, cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import { test } from "node:test";
import { build } from "esbuild";

const browser = process.env.OE_BROWSER ?? ["/usr/bin/chromium-headless-shell", "/usr/bin/chromium"].find((p) => existsSync(p));
const web = new URL("..", import.meta.url).pathname;
const shot = new URL("../../bin/shot.mjs", import.meta.url).pathname;
const MIME: Record<string, string> = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };

async function bundle(dir: string) {
  await build({ entryPoints: [join(web, "main.ts")], bundle: true, format: "esm", target: "es2022", outfile: join(dir, "main.js"), logLevel: "silent" });
  for (const f of ["index.html", "theme.css"]) copyFileSync(join(web, f), join(dir, f));
  copyFileSync(join(web, "ui", "kit", "kit.css"), join(dir, "kit.css"));
  copyFileSync(join(web, "ui", "frame", "frame.css"), join(dir, "frame.css"));
  copyFileSync(join(web, "ui", "panels", "stock.css"), join(dir, "stock.css"));
  cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
  copyFileSync(join(web, "fonts", "fonts.css"), join(dir, "fonts.css"));
  const { themesCss } = await import("../themes/css.ts");
  const { DEFAULT_THEME_ID, themes } = await import("../themes/index.ts");
  writeFileSync(join(dir, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
}

const good = JSON.parse(readFileSync(join(web, "test", "fixtures", "games", "track.json"), "utf8"));
// A state the frame cannot draw (stands in for whatever threw in the owner's browser): no players.
const broken = { ...good, state: { ...good.state, players: null } };

// mode: "500" -> GET /games/1 answers 500; "broken" -> a state that throws while drawing; "ok" -> good.
function stub(dir: string) {
  let mode = "500";
  const clientErrors: unknown[] = [];
  const server: Server = createServer((req, res) => {
    const p = new URL(req.url!, "http://x").pathname;
    const json = (o: unknown, status = 200) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(o)); };
    if (p === "/me") return json({ id: "p0", name: "p0" });
    if (p === "/map") return json({ error: "not_found", message: "no map in this test" }, 404);
    if (p.startsWith("/__mode/")) { mode = p.slice("/__mode/".length); return json({ mode }); }
    if (p === "/__client_errors") return json(clientErrors);
    if (p === "/games/1/version") return json({ seq: good.seq, status: "active" });
    if (p === "/games/1") {
      if (mode === "500") return json({ error: "internal_error", message: "boom" }, 500);
      return json(mode === "broken" ? broken : good);
    }
    if (p === "/client-errors" && req.method === "POST") {
      let b = "";
      req.on("data", (c) => { b += c; });
      req.on("end", () => { clientErrors.push(JSON.parse(b)); json({ ok: true }); });
      return;
    }
    const f = join(dir, p === "/" ? "index.html" : p);
    if (existsSync(f)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); } else { res.writeHead(404); res.end(); }
  });
  return { server, clientErrors };
}

async function run(dir: string, port: number, checks: string): Promise<number> {
  const { spawn } = await import("node:child_process");
  return new Promise<number>((resolve) => {
    const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/#/game/1`, join(dir, "out.png"), "--width", "1280", "--height", "800", "--wait-for", ".frame .band:not([hidden])", "--eval", checks], { stdio: "pipe" });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
  });
}

const CHECKS = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  const band = () => q(".frame .band");
  const until = async (what, f) => { for (let i = 0; i < 60; i++) { if (f()) return; await sleep(100); } fail("timed out waiting for " + what + "; band: " + band().textContent); };
  // 1) The first state fails with 500: the band names status and request, has "Jetzt", the sheet says loading.
  await until("server error band", () => !band().hidden && /HTTP 500/.test(band().textContent));
  if (!/GET \/games\/1/.test(band().textContent)) fail("band does not name the request: " + band().textContent);
  if (!/boom/.test(band().textContent)) fail("band does not carry the server message: " + band().textContent);
  if (!band().querySelector("button")) fail("no retry button");
  if (!q(".frame-loading")) fail("no loading line while no state is drawn");
  // 2) A state that cannot be drawn: named as a display error, the band stays (no silent map-only page).
  await fetch("/__mode/broken");
  band().querySelector("button").click();
  await until("display error band", () => !band().hidden && /Anzeigefehler/.test(band().textContent));
  await sleep(2500); // the next regular check must not clear it (the bug: seq taken, band hidden)
  if (band().hidden || !/Anzeigefehler/.test(band().textContent)) fail("display error band vanished: " + band().textContent);
  if (!band().querySelector("button")) fail("no retry button on the display error");
  // 3) A good state: the frame is drawn and the band goes away.
  await fetch("/__mode/ok");
  band().querySelector("button").click();
  await until("frame drawn", () => band().hidden && q(".frame-roundbar").textContent.trim() !== "" && document.querySelectorAll(".frame-player").length >= 3);
  if (q(".frame-loading")) fail("loading line stays after the state is drawn");
})()`;

test("opening a game: a failing first state is named in the band with a retry, never a silent map-only page (#294)", { skip: browser ? false : "no headless browser installed" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-open-game-test-"));
  try {
    await bundle(dir);
    const { server, clientErrors } = stub(dir);
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as { port: number }).port;
    const code = await run(dir, port, CHECKS);
    server.closeAllConnections();
    server.close();
    assert.equal(code, 0, "page checks failed (see stderr)");
    assert.ok(clientErrors.length >= 1, "the display error was reported to the server");
    assert.match(String((clientErrors[0] as { message: string }).message), /TypeError/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
