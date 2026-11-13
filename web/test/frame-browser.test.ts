// The game frame in a real browser (#45): bundles main.ts, serves it with a stub API (one recorded game
// state per run, POST /games/1/actions recorded), and drives the page with bin/shot --eval. The page
// script throws on the first failed check, so bin/shot exits non-zero. Skipped without a headless browser.
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
  cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
  copyFileSync(join(web, "fonts", "fonts.css"), join(dir, "fonts.css"));
  const { themesCss } = await import("../themes/css.ts");
  const { DEFAULT_THEME_ID, themes } = await import("../themes/index.ts");
  writeFileSync(join(dir, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
}

function stub(dir: string, fixture: string, failWith?: { status: number; body: unknown }) {
  let game = JSON.parse(readFileSync(join(web, "test", "fixtures", "games", `${fixture}.json`), "utf8"));
  const posted: { action: Record<string, unknown>; seq: number }[] = [];
  const server: Server = createServer((req, res) => {
    const p = new URL(req.url!, "http://x").pathname;
    const json = (o: unknown, status = 200) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(o)); };
    if (p === "/me") return json({ id: "p0", name: "p0" });
    if (p === "/games/1") return json(game);
    if (p === "/games/1/version") return json({ seq: game.seq, status: "active" });
    if (p === "/__posted") return json(posted);
    if (p === "/games/1/actions" && req.method === "POST") {
      let b = "";
      req.on("data", (c) => { b += c; });
      req.on("end", () => {
        posted.push(JSON.parse(b));
        if (failWith) return json(failWith.body, failWith.status);
        game = { ...game, seq: game.seq + 1 };
        json(game);
      });
      return;
    }
    const f = join(dir, p === "/" ? "index.html" : p);
    if (existsSync(f)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); } else { res.writeHead(404); res.end(); }
  });
  return { server, posted };
}

// Runs inside the page after the frame is drawn.
const CHECKS = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  for (const s of [".frame-roundbar", ".frame-players", ".frame-context", ".frame-main", ".frame-outliner", ".frame-bar"]) if (!q(s)) fail("missing " + s);
  const box = (s) => q(s).getBoundingClientRect();
  if (box(".frame-bar").bottom > innerHeight + 1 || box(".frame-roundbar").top < -1) fail("bars leave the window");
  if (!q(".frame-who").textContent.trim()) fail("no who-acts text");
  if (q(".frame-who").dataset.mine !== "true") fail("not marked as mine");
  if (q(".frame-players").querySelectorAll(".frame-player").length < 3) fail("player bar");
  // Select the first generic entry; nothing may be sent yet.
  const entry = q(".frame-entry");
  if (!entry) fail("no generic entry");
  const before = await (await fetch("/__posted")).json();
  entry.click();
  await sleep(50);
  if (!q(".kit-order")) fail("no order after selecting");
  if ((await (await fetch("/__posted")).json()).length !== before.length) fail("select sent something");
  q(".kit-main-btn").click();
  await sleep(600);
  const posted = await (await fetch("/__posted")).json();
  if (posted.length !== before.length + 1) fail("confirm did not send exactly one action: " + posted.length);
  const sent = posted.at(-1);
  if (typeof sent.seq !== "number") fail("no seq");
  if (!q(".frame-bar")) fail("frame gone");
  if (q(".kit-order")) fail("selection stays after a successful send");
  window.__sent = sent;
})()`;

test("frame in the browser: bars drawn, selecting does not send, the main button sends the exact action", { skip: browser ? false : "no headless browser installed" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-frame-test-"));
  try {
    await bundle(dir);
    const { server, posted } = stub(dir, "track");
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as { port: number }).port;
    const out = join(dir, "out.png");
    // spawnSync would block the event loop that serves the stub; use the async spawn through a promise.
    const { spawn } = await import("node:child_process");
    const code = await new Promise<number>((resolve) => {
      const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/#/game/1`, out, "--width", "1440", "--height", "900", "--wait-for", ".frame-entry", "--eval", CHECKS], { stdio: "pipe" });
      let err = "";
      child.stderr.on("data", (d) => { err += d; });
      child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
    });
    server.closeAllConnections();
    server.close();
    assert.equal(code, 0, "page checks failed (see stderr)");
    assert.equal(posted.length, 1);
    const first = JSON.parse(readFileSync(join(web, "test", "fixtures", "games", "track.json"), "utf8")).state.prompt.actions;
    assert.ok(first.some((a: Record<string, unknown>) => JSON.stringify(a) === JSON.stringify(posted[0]!.action)), "sent action is one of the offered actions, unchanged");
    assert.equal(posted[0]!.seq, JSON.parse(readFileSync(join(web, "test", "fixtures", "games", "track.json"), "utf8")).seq);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
