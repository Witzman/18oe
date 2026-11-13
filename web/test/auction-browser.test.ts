// The auction panel in a real browser (#46): bundles main.ts, serves it with a stub API (one recorded engine
// state per run, POST /games/1/actions recorded) and drives the page with bin/shot --eval. The page script
// throws on the first failed check. Skipped without a headless browser.
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
  copyFileSync(join(web, "ui", "panels", "stock.css"), join(dir, "stock.css"));
  cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
  copyFileSync(join(web, "fonts", "fonts.css"), join(dir, "fonts.css"));
  const { themesCss } = await import("../themes/css.ts");
  const { DEFAULT_THEME_ID, themes } = await import("../themes/index.ts");
  writeFileSync(join(dir, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
}

const fixture = (name: string) => JSON.parse(readFileSync(join(web, "test", "fixtures", "games", `${name}.json`), "utf8"));

function stub(dir: string, start: { seq: number }, failWith?: { status: number; body: unknown }) {
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

// spawnSync would block the event loop that serves the stub, so the browser runs as an async child.
async function run(dir: string, port: number, checks: string): Promise<number> {
  const { spawn } = await import("node:child_process");
  return new Promise<number>((resolve) => {
    const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/#/game/1`, join(dir, "out.png"), "--width", "1440", "--height", "900", "--wait-for", ".auction-card", "--eval", checks], { stdio: "pipe" });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
  });
}

const CHECKS_BID = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  const posted = async () => (await (await fetch("/__posted")).json());
  if (document.querySelectorAll(".auction-card").length !== 22) fail("cards: " + document.querySelectorAll(".auction-card").length);
  if (!q('.auction-row[data-top="true"]')) fail("no top row");
  if (!q(".frame-tabs") || q(".frame-tabs").hidden) fail("view tabs missing");
  if (q(".frame-entry")) fail("generic bar still offers the claimed actions");
  if (!/Wähle ein Los/.test(q(".kit-order-sentence").textContent)) fail("sentence: " + q(".kit-order-sentence").textContent);
  if (!q(".kit-main-btn").disabled) fail("main button open without a choice");
  q('.auction-card[data-card="A"]').click();
  await sleep(50);
  if (!/Kaufen: Silver Banner Line für £120/.test(q(".kit-order-sentence").textContent)) fail("buy sentence: " + q(".kit-order-sentence").textContent);
  if ((await posted()).length !== 0) fail("choosing sent something");
  const input = q(".auction-bidform input");
  if (!input || input.value !== "120") fail("amount field " + (input && input.value));
  if (document.activeElement !== input) fail("amount field not focused");
  const type = async (v) => { input.value = v; input.dispatchEvent(new Event("input", { bubbles: true })); await sleep(30); };
  await type("131");
  if (!q(".kit-main-btn").disabled) fail("odd amount confirmable");
  if (q("#auction-amount-hint").dataset.bad !== "true") fail("hint not marked");
  if (document.activeElement !== input) fail("input lost the focus while typing");
  await type("130");
  if (!/Bieten: Silver Banner Line mit £130/.test(q(".kit-order-sentence").textContent)) fail("bid sentence: " + q(".kit-order-sentence").textContent);
  if (!/Bieten £130/.test(q(".kit-main-btn").textContent)) fail("button: " + q(".kit-main-btn").textContent);
  q(".kit-main-btn").click();
  await sleep(600);
  const p = await posted();
  if (p.length !== 1) fail("sent " + p.length);
  window.__ok = true;
})()`;

const CHECKS_PASS = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  const side = q(".frame-order-side .kit-side-btn") || fail("no pass button");
  if (!/Passen/.test(side.textContent)) fail("label " + side.textContent);
  q('.auction-card[data-card="WS"]').click();
  await sleep(50);
  if (!/Gebot vormerken: Wien Südbahnhof mit £40/.test(q(".kit-order-sentence").textContent)) fail("sentence: " + q(".kit-order-sentence").textContent);
  q(".frame-order-side .kit-side-btn").click();
  await sleep(600);
  const p = await (await fetch("/__posted")).json();
  if (p.length !== 1) fail("pass not sent once: " + p.length);
})()`;

async function scenario(name: string, checks: string) {
  const dir = mkdtempSync(join(tmpdir(), "oe-auction-test-"));
  try {
    await bundle(dir);
    const game = fixture(name);
    const { server, posted } = stub(dir, game);
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const code = await run(dir, (server.address() as { port: number }).port, checks);
    server.closeAllConnections();
    server.close();
    assert.equal(code, 0, "page checks failed (see stderr)");
    return { posted, game };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test("auction in the browser: choosing sends nothing, the amount field guards the range, the main button sends the exact bid", { skip: browser ? false : "no headless browser installed" }, async () => {
  const { posted, game } = await scenario("auction-minor-top", CHECKS_BID);
  assert.equal(posted.length, 1);
  assert.deepEqual(posted[0]!.action, { type: "bid", entity: "p3", entity_type: "player", company: "A", price: 130 });
  assert.equal(posted[0]!.seq, game.seq);
});

test("auction in the browser: the pass button sends the offered pass", { skip: browser ? false : "no headless browser installed" }, async () => {
  const { posted, game } = await scenario("auction-bids", CHECKS_PASS);
  assert.equal(posted.length, 1);
  assert.deepEqual(posted[0]!.action, game.state.prompt.actions.find((a: Record<string, unknown>) => a.type === "pass"));
});

const CHECKS_RUNNING = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  if (!q(".auction-running") || !/Silver Banner Line/.test(q(".auction-running").textContent)) fail("no running auction box");
  if (!/Höchstgebot £130 von p3/.test(q(".auction-running").textContent)) fail("high bid: " + q(".auction-running").textContent);
  if (q(".auction-card[data-running=true]").getAttribute("aria-pressed") !== "true") fail("running lot not preselected");
  if (q(".auction-bidform input").value !== "135") fail("amount " + q(".auction-bidform input").value);
  if (!/Bieten: Silver Banner Line mit £135/.test(q(".kit-order-sentence").textContent)) fail("sentence " + q(".kit-order-sentence").textContent);
  if (q('.auction-card[data-card="B"]').dataset.state !== "blocked") fail("other lots must not be choosable during the auction");
  q(".kit-main-btn").click();
  await sleep(600);
  if ((await (await fetch("/__posted")).json()).length !== 1) fail("not sent");
})()`;

test("auction in the browser: a running auction preselects its lot and bids from the offered range", { skip: browser ? false : "no headless browser installed" }, async () => {
  const { posted } = await scenario("auction-open", CHECKS_RUNNING);
  assert.deepEqual(posted[0]!.action, { type: "bid", entity: "p0", entity_type: "player", company: "A", price: 135 });
});
