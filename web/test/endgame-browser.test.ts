// Final standings in a real browser (#176): a finished state shows the board, no action bar, and the map/log/lobby
// buttons work. Bundles main.ts, stub API with the recorded finished state; skipped without a headless browser.
// OE_SHOT_DIR=<dir> keeps screenshots of both themes there (for the visual check).
import assert from "node:assert/strict";
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
  const end = q(".frame-end");
  if (!end || end.dataset.open !== "true") fail("no open final standings");
  if (end.querySelectorAll("tbody tr").length < 3) fail("ranking rows");
  if (end.querySelectorAll(".frame-end-card").length < 3) fail("player cards");
  if (!q(".frame-roundbar").textContent.includes("beendet")) fail("round bar does not say the game is over");
  if (q(".frame-entry") || q(".kit-main-btn")) fail("actions offered after the end");
  if (q(".frame-bar .frame-toggle[aria-expanded]") && /Aktionen/.test(q(".frame-bar").textContent)) fail("action toggle present");
  const lobby = end.querySelector("a[href='#/']");
  if (!lobby) fail("no lobby link");
  const box = end.getBoundingClientRect();
  if (box.right > innerWidth + 1) fail("board overflows horizontally");
  // Log button opens the log drawer.
  [...end.querySelectorAll("button")].find((b) => b.textContent === "Protokoll").click();
  await sleep(50);
  if (!q(".frame-log")) fail("log drawer did not open");
  // Map button collapses the board; the views are still there.
  [...end.querySelectorAll("button")].find((b) => b.textContent === "Karte ansehen").click();
  await sleep(50);
  if (q(".frame-end").dataset.open !== "false") fail("board did not collapse");
  if (!q(".frame-view")) fail("view gone");
  q(".frame-end-show").click();
  await sleep(50);
  if (q(".frame-end").dataset.open !== "true") fail("board did not reopen");
})()`;

test("final standings in the browser, both themes", { skip: browser ? false : "no headless browser installed" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-end-test-"));
  const keep = process.env.OE_SHOT_DIR;
  try {
    await bundle(dir);
    const game = JSON.parse(readFileSync(join(web, "test", "fixtures", "games", "finished.json"), "utf8"));
    const server = createServer((req, res) => {
      const p = new URL(req.url!, "http://x").pathname;
      const json = (o: unknown) => { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify(o)); };
      if (p === "/me") return json({ id: game.viewer, name: game.viewer });
      if (p === "/games/1") return json(game);
      if (p === "/games/1/version") return json({ seq: game.seq, status: "finished" });
      const f = join(dir, p === "/" ? "index.html" : p);
      if (existsSync(f)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); } else { res.writeHead(404); res.end(); }
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as { port: number }).port;
    const { spawn } = await import("node:child_process");
    for (const theme of ["brett", "atlas"]) for (const [w, h] of [[1440, 900], [720, 900]] as const) {
      // Narrow runs only take the picture; the interaction checks run at full width.
      const out = keep ? join(keep, `end-${theme}-${w}.png`) : join(dir, "out.png");
      const args = [shot, `http://127.0.0.1:${port}/#/game/1`, out, "--width", String(w), "--height", String(h), "--theme", theme, "--wait-for", ".frame-end"];
      if (w === 1440) args.push("--eval", CHECKS);
      const code = await new Promise<number>((resolve) => {
        const child = spawn(process.execPath, args, { stdio: "pipe" });
        let err = "";
        child.stderr.on("data", (d) => { err += d; });
        child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
      });
      assert.equal(code, 0, `${theme} ${w}: page checks failed (see stderr)`);
    }
    server.closeAllConnections();
    server.close();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
