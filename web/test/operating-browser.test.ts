// The operating sheet in a real browser (#49): same stub-server approach as auction-browser.test.ts.
// Skipped without a headless browser. Run under the shared lock (heavy job).
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
  copyFileSync(join(web, "ui", "panels", "auction.css"), join(dir, "auction.css"));
  copyFileSync(join(web, "ui", "panels", "concession.css"), join(dir, "concession.css"));
  copyFileSync(join(web, "ui", "panels", "train.css"), join(dir, "train.css"));
  copyFileSync(join(web, "ui", "panels", "operating.css"), join(dir, "operating.css"));
  copyFileSync(join(web, "ui", "panels", "stock.css"), join(dir, "stock.css"));
  cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
  copyFileSync(join(web, "fonts", "fonts.css"), join(dir, "fonts.css"));
  const { themesCss } = await import("../themes/css.ts");
  const { DEFAULT_THEME_ID, themes } = await import("../themes/index.ts");
  writeFileSync(join(dir, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
}

const fixture = (name: string) => JSON.parse(readFileSync(join(web, "test", "fixtures", "games", `${name}.json`), "utf8"));

function stub(dir: string, start: { seq: number }) {
  let game: { seq: number } = start;
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
      req.on("end", () => { posted.push(JSON.parse(b)); game = { ...game, seq: game.seq + 1 }; json(game); });
      return;
    }
    const f = join(dir, p === "/" ? "index.html" : p);
    if (existsSync(f)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); } else { res.writeHead(404); res.end(); }
  });
  return { server, posted };
}

async function run(dir: string, port: number, waitFor: string, checks: string): Promise<number> {
  const { spawn } = await import("node:child_process");
  return new Promise<number>((resolve) => {
    const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/#/game/1`, join(dir, "out.png"), "--width", process.env.OE_W ?? "1440", "--height", process.env.OE_H ?? "900", "--wait-for", waitFor, ...(process.env.OE_THEME ? ["--theme", process.env.OE_THEME] : []), "--eval", checks], { stdio: "pipe" });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
  });
}

const HEAD = String.raw`const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  const small = (sel) => { for (const e of document.querySelectorAll(sel)) { const r = e.getBoundingClientRect(); if (r.height < 43.5) fail(sel + " too small: " + r.height); } };`;

const ROUTE = String.raw`(async () => {
  ${HEAD}
  if (!q(".op-head") || !/B/.test(q(".op-head").textContent)) fail("head");
  if (document.querySelectorAll(".kit-ladder li").length !== 5 || !q('.kit-ladder [aria-current="step"]')) fail("ladder");
  const rows = document.querySelectorAll(".op-table tbody tr");
  if (rows.length !== 1 || !/2\+2-0/.test(rows[0].textContent) || !/£60/.test(rows[0].textContent)) fail("route row: " + (rows[0] && rows[0].textContent));
  if (!/£60/.test(q(".op-total").textContent)) fail("total");
  if (q(".frame-entry")) fail("generic bar still offers the claimed action");
  if (q(".kit-main-btn").disabled) fail("main button locked");
  if ((await (await fetch("/__posted")).json()).length !== 0) fail("previewing sent something");
  q(".kit-main-btn").click();
  await sleep(600);
  if ((await (await fetch("/__posted")).json()).length !== 1) fail("not sent once");
})()`;

const ORDER = String.raw`(async () => {
  ${HEAD}
  const items = [...document.querySelectorAll(".or-item")];
  if (items.map((i) => i.dataset.id).join() !== "A,B,D,F,H,M") fail("order " + items.map((i) => i.dataset.id));
  if (items.map((i) => i.dataset.state).join() !== "done,current,next,next,next,next") fail("states");
  if (document.querySelectorAll('.or-item[data-mine="true"]').length !== 2) fail("own marks");
  if (!q('.or-item[data-id="A"]').dataset.bot || q('.or-item[data-id="A"]').dataset.bot !== "true") fail("bot mark");
  if (!/du bist am Zug/.test(q(".or-acting").textContent) || q(".or-acting").dataset.mine !== "true") fail("acting card: " + q(".or-acting").textContent);
  small(".or-item"); small(".or-acting");
  const w = document.documentElement.scrollWidth; if (w > window.innerWidth + 1) fail("horizontal overflow " + w);
})()`;

const DIVIDEND = String.raw`(async () => {
  ${HEAD}
  const opts = document.querySelectorAll(".op-opt");
  if (opts.length !== 3) fail("options " + opts.length);
  small(".op-opt");
  if (q(".frame-entry")) fail("generic bar still offers the claimed actions");
  if (!q(".kit-main-btn").disabled) fail("main button open before a choice");
  q('.op-opt[data-kind="payout"]').click();
  await sleep(200);
  if (q(".kit-main-btn").disabled) fail("main button locked after the choice");
  if (!/Alles ausschütten/.test(q(".kit-order-sentence").textContent)) fail("sentence: " + q(".kit-order-sentence").textContent);
  if ((await (await fetch("/__posted")).json()).length !== 0) fail("choosing sent something");
  q(".kit-main-btn").click();
  await sleep(600);
  if ((await (await fetch("/__posted")).json()).length !== 1) fail("not sent once");
})()`;

async function scenario(name: string, waitFor: string, checks: string) {
  const dir = mkdtempSync(join(tmpdir(), "oe-op-test-"));
  try {
    await bundle(dir);
    const game = fixture(name);
    const { server, posted } = stub(dir, game);
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const code = await run(dir, (server.address() as { port: number }).port, waitFor, checks);
    if (process.env.OE_SHOT_DIR) copyFileSync(join(dir, "out.png"), join(process.env.OE_SHOT_DIR, `${name}-${process.env.OE_THEME ?? "default"}.png`));
    server.closeAllConnections();
    server.close();
    assert.equal(code, 0, "page checks failed (see stderr)");
    return { posted, game };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}


test("operating sheet in the browser: the route is previewed and the main button sends exactly the offered run_routes", { skip: browser ? false : "no headless browser installed" }, async () => {
  const { posted, game } = await scenario("operating-route", ".op-table", ROUTE);
  assert.equal(posted.length, 1);
  assert.deepEqual(posted[0]!.action, game.state.prompt.actions[0]);
  assert.equal(posted[0]!.seq, game.seq);
});

test("operating sheet in the browser: dividend needs a choice, then the main button sends exactly that offered action", { skip: browser ? false : "no headless browser installed" }, async () => {
  const { posted, game } = await scenario("operating-dividend", ".op-opt", DIVIDEND);
  assert.equal(posted.length, 1);
  assert.deepEqual(posted[0]!.action, game.state.prompt.actions[2]);
});

test("operating order in the browser: acting company card, order list with done, current, own and bot marks", { skip: browser ? false : "no headless browser installed" }, async () => {
  await scenario("operating-route", ".or-item", ORDER);
});
