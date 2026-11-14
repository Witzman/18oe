// Versionsangabe im Browser (#271): Anmeldeseite (Fußzeile) und Spielrahmen (Knopf + Dialog) zeigen
// genau die Werte, die /healthz liefert. Bundelt mit `define` wie web/build.mjs. Ohne Browser übersprungen.
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
const HEALTH = { status: "ok", build: "abcdef123456", version: "0.1.0-dev", engine: "06b3f0b37+abcdef123456" };

async function bundle(dir: string, version: string) {
  await build({ entryPoints: [join(web, "main.ts")], bundle: true, format: "esm", target: "es2022", outfile: join(dir, "main.js"), logLevel: "silent", define: { __OE_VERSION__: JSON.stringify(version) } });
  for (const f of ["index.html", "theme.css"]) copyFileSync(join(web, f), join(dir, f));
  copyFileSync(join(web, "ui", "kit", "kit.css"), join(dir, "kit.css"));
  copyFileSync(join(web, "ui", "frame", "frame.css"), join(dir, "frame.css"));
  cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
  copyFileSync(join(web, "fonts", "fonts.css"), join(dir, "fonts.css"));
  const { themesCss } = await import("../themes/css.ts");
  const { DEFAULT_THEME_ID, themes } = await import("../themes/index.ts");
  writeFileSync(join(dir, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
}

function stub(dir: string, loggedIn: boolean): Server {
  const game = JSON.parse(readFileSync(join(web, "test", "fixtures", "games", "track.json"), "utf8"));
  return createServer((req, res) => {
    const p = new URL(req.url!, "http://x").pathname;
    const json = (o: unknown, status = 200) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(o)); };
    if (p === "/healthz") return json(HEALTH);
    if (p === "/me") return loggedIn ? json({ id: "p0", name: "p0" }) : json({ error: "login_required", message: "x" }, 401);
    if (p === "/games/1") return json(game);
    if (p === "/games/1/version") return json({ seq: game.seq, status: "active" });
    const f = join(dir, p === "/" ? "index.html" : p);
    if (existsSync(f)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); } else { res.writeHead(404); res.end(); }
  });
}

async function run(dir: string, port: number, hash: string, waitFor: string, checks: string, extra: string[] = []): Promise<number> {
  const { spawn } = await import("node:child_process");
  return new Promise<number>((resolve) => {
    const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/${hash}`, join(dir, `out-${hash.replace(/\W/g, "")}.png`), "--width", "1440", "--height", "900", "--wait-for", waitFor, "--eval", checks, ...extra], { stdio: "pipe" });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
  });
}

const EXPECT = `Version ${HEALTH.version} · Build ${HEALTH.build} · Engine ${HEALTH.engine}`;

const LOGIN_CHECKS = String.raw`(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  await sleep(400);
  const t = document.querySelector(".version-note")?.textContent;
  if (t !== ${JSON.stringify(EXPECT)}) throw new Error("login footer: " + t);
})()`;

const FRAME_CHECKS = String.raw`(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const btn = document.querySelector(".version-open") || (() => { throw new Error("no version button"); })();
  btn.click();
  await sleep(500);
  const dlg = document.querySelector(".version-dialog");
  if (!dlg || !dlg.open) throw new Error("dialog not open");
  const text = dlg.textContent;
  for (const v of ${JSON.stringify([HEALTH.version, HEALTH.build, HEALTH.engine])}) if (!text.includes(v)) throw new Error("dialog lacks " + v + ": " + text);
  if (dlg.querySelector("[role=alert]")) throw new Error("unexpected stale warning");
})()`;

for (const [name, loggedIn, hash, waitFor, checks] of [
  ["login page footer matches /healthz", false, "#/login", ".version-note", LOGIN_CHECKS],
  ["game frame dialog matches /healthz", true, "#/game/1", ".frame-bar", FRAME_CHECKS],
] as const) {
  test(`version display: ${name}`, { skip: browser ? false : "no headless browser installed" }, async () => {
    const dir = mkdtempSync(join(tmpdir(), "oe-version-test-"));
    try {
      await bundle(dir, HEALTH.version);
      const server = stub(dir, loggedIn);
      await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
      const code = await run(dir, (server.address() as { port: number }).port, hash, waitFor, checks);
      server.closeAllConnections();
      server.close();
      assert.equal(code, 0, "page checks failed (see stderr)");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
}
