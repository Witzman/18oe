// "Du bist dran" im Browser (#163): Seitentitel, Favicon, Rundenleiste und Marke in der Partieliste folgen
// viewer_to_act. Ohne Browser übersprungen.
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

const SUMMARY = (id: number, mine: boolean) => ({ id, status: "active", seats: [], seq: 5, created_at: "2026-11-13", round: { type: "operating", number: 1, turn: 1 }, acting: [], viewer_to_act: mine });

function stub(dir: string, mine: boolean): Server {
  const game = JSON.parse(readFileSync(join(web, "test", "fixtures", "games", "track.json"), "utf8"));
  game.state.prompt.viewer_to_act = mine;
  return createServer((req, res) => {
    const p = new URL(req.url!, "http://x").pathname;
    const json = (o: unknown, status = 200) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(o)); };
    if (p === "/healthz") return json(HEALTH);
    if (p === "/me") return json({ id: "p0", name: "p0" });
    if (p === "/games") return json({ games: [SUMMARY(1, mine), SUMMARY(2, false)] });
    if (p === "/games/1") return json(game);
    if (p === "/games/1/version") return json({ seq: game.seq, status: "active", round: { type: "operating", number: 1, turn: 1 }, acting: [], viewer_to_act: mine });
    const f = join(dir, p === "/" ? "index.html" : p);
    if (existsSync(f)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); } else { res.writeHead(404); res.end(); }
  });
}

async function run(dir: string, port: number, hash: string, waitFor: string, checks: string, extra: string[] = []): Promise<number> {
  const { spawn } = await import("node:child_process");
  return new Promise<number>((resolve) => {
    const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/${hash}`, join(dir, `out-${hash.replace(/\W/g, "")}.png`), "--width", "1440", "--height", "900", "--wait-for", waitFor, "--eval", checks, ...extra, ...(process.env.OE_TURN_SHOT_ARGS?.split(" ") ?? [])], { stdio: "pipe" });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
  });
}

const dotIcon = (on: boolean) => String.raw`(() => {
  const href = decodeURIComponent((document.querySelector('link[rel="icon"]')?.href ?? "").replace("data:image/svg+xml,", ""));
  if (href.includes("<circle") !== ${on}) throw new Error("favicon dot mismatch: " + href);
})()`;

const GAME_CHECKS = (on: boolean) => String.raw`(async () => {
  await new Promise((r) => setTimeout(r, 400));
  const want = ${on} ? "(●) 18OE · Partie 1" : "18OE · Partie 1";
  if (document.title !== want) throw new Error("title: " + document.title);
  ${dotIcon(on)};
  const who = document.querySelector(".frame-who");
  if ((who.dataset.mine === "true") !== ${on}) throw new Error("round bar mine: " + who.dataset.mine);
  if (${on} && !who.textContent.includes("Du bist dran")) throw new Error("who: " + who.textContent);
})()`;

const LOBBY_CHECKS = String.raw`(async () => {
  await new Promise((r) => setTimeout(r, 400));
  if (document.title !== "(●) 18OE") throw new Error("title: " + document.title);
  ${dotIcon(true)};
  const rows = [...document.querySelectorAll(".game-row")];
  const mark = (r) => r.querySelector(".game-turn")?.textContent;
  if (mark(rows.find((r) => r.querySelector(".game-link").textContent.includes("2"))) !== undefined) throw new Error("mark on game 2");
  const mine = rows.find((r) => r.querySelector(".game-link").textContent.includes("1"));
  if (mark(mine) !== "Du bist dran") throw new Error("no mark on game 1");
  for (const a of mine.querySelectorAll("a")) if (a.getBoundingClientRect().height < 44) throw new Error("touch target below 44 px");
})()`;

for (const [name, mine, hash, waitFor, checks] of [
  ["game page, to act: title, favicon, round bar", true, "#/game/1", ".frame-who", GAME_CHECKS(true)],
  ["game page, waiting: no dot", false, "#/game/1", ".frame-who", GAME_CHECKS(false)],
  ["game list: mark on the game to act, title and favicon with dot", true, "#/", ".game-row", LOBBY_CHECKS],
] as const) {
  for (const theme of ["brett", "atlas"]) {
    test(`du bist dran (${theme}): ${name}`, { skip: browser ? false : "no headless browser installed" }, async () => {
      const dir = mkdtempSync(join(tmpdir(), "oe-turn-test-"));
      try {
        await bundle(dir, HEALTH.version);
        const server = stub(dir, mine);
        await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
        const code = await run(dir, (server.address() as { port: number }).port, hash, waitFor, checks, ["--theme", theme]);
        // Sichtprüfung von Hand: OE_TURN_KEEP=<Ordner> behält die Bilder (mit OE_TURN_SHOT_ARGS="--device ipad").
        if (process.env.OE_TURN_KEEP) copyFileSync(join(dir, `out-${hash.replace(/\W/g, "")}.png`), join(process.env.OE_TURN_KEEP, `${theme}-${name.replace(/\W+/g, "_")}.png`));
        server.closeAllConnections();
        server.close();
        assert.equal(code, 0, "page checks failed (see stderr)");
      } finally { rmSync(dir, { recursive: true, force: true }); }
    });
  }
}
