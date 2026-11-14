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
  copyFileSync(join(web, "ui", "panels", "stock.css"), join(dir, "stock.css"));
  cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
  copyFileSync(join(web, "fonts", "fonts.css"), join(dir, "fonts.css"));
  const { themesCss } = await import("../themes/css.ts");
  const { DEFAULT_THEME_ID, themes } = await import("../themes/index.ts");
  writeFileSync(join(dir, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
}

const GENERIC = "merge-minor";
const LONG = Array.from({ length: 1200 }, (_, i) => ({ action: i + 1, text: i === 0 ? "Bot 1 has priority deal" : `log line ${i + 1}` }));
const fixture = (name: string) => JSON.parse(readFileSync(join(web, "test", "fixtures", "games", `${name}.json`), "utf8"));

function stub(dir: string, start: { seq: number }, logLines: { action: number; text: string }[]) {
  let game: { seq: number } = start;
  const posted: { action: Record<string, unknown>; seq: number }[] = [];
  const server: Server = createServer((req, res) => {
    const p = new URL(req.url!, "http://x").pathname;
    const json = (o: unknown, status = 200) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(o)); };
    if (p === "/me") return json({ id: "p0", name: "p0" });
    if (p === "/games/1") return json(game);
    if (p === "/games/1/version") return json({ seq: game.seq, status: "active" });
    if (p === "/__posted") return json(posted);
    if (p === "/games/1/log") {
      const u = new URL(req.url!, "http://x");
      const from = Number(u.searchParams.get("from") ?? 0), limit = Number(u.searchParams.get("limit") ?? 100);
      const rest = logLines.filter((l) => l.action > from), lines = rest.slice(0, limit);
      return json({ lines, next: rest.length > limit ? lines.at(-1)!.action : null, seq: game.seq });
    }
    if (p === "/games/1/actions" && req.method === "POST") {
      let b = "";
      req.on("data", (c) => { b += c; });
      req.on("end", () => {
        posted.push(JSON.parse(b));
        logLines.push({ action: logLines.length + 1, text: "appended line" });
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


async function run(dir: string, port: number, checks: string, width = 1440, height = 900): Promise<number> {
  const { spawn } = await import("node:child_process");
  return new Promise<number>((resolve) => {
    const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/#/game/1`, join(dir, "out.png"), "--width", String(width), "--height", String(height), "--wait-for", ".frame-entry", "--eval", checks], { stdio: "pipe" });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
  });
}

// Runs inside the page: the log sheet holds the whole game from its first line (#292).
const CHECKS = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  const toggle = [...document.querySelectorAll(".frame-toggle")].find((b) => /Protokoll/.test(b.textContent)) || fail("no log toggle");
  toggle.click();
  await sleep(800);
  const list = q(".frame-log-scroll") || fail("no log list");
  const lis = () => list.querySelectorAll("li");
  if (lis().length !== 1200) fail("not the whole game: " + lis().length);
  if (list.scrollTop + list.clientHeight < list.scrollHeight - 8) fail("not at the end on open");
  list.scrollTop = 0;
  await sleep(100);
  if (!/priority deal/.test(lis()[0].textContent)) fail("first line wrong");
  const r = lis()[0].getBoundingClientRect(), lr = list.getBoundingClientRect();
  if (r.top < lr.top - 1 || r.bottom > lr.bottom + 1) fail("first line not reachable");
  q(".frame-entry").click();
  await sleep(50);
  q(".kit-main-btn").click();
  await sleep(1200);
  if (lis().length !== 1201) fail("new line not appended: " + lis().length);
  if (list.scrollTop > 2) fail("scroll position lost: " + list.scrollTop);
  if (!/appended/.test(lis()[1200].textContent)) fail("appended at the wrong place");
})()`;

test("log sheet shows the whole game from the first line and appends new lines without losing the scroll position", { skip: browser ? false : "no headless browser installed" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-log-test-"));
  try {
    await bundle(dir);
    const { server } = stub(dir, fixture(GENERIC), [...LONG]);
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as { port: number }).port;
    const code = await run(dir, port, CHECKS);
    server.closeAllConnections();
    server.close();
    assert.equal(code, 0, "page checks failed (see stderr)");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
