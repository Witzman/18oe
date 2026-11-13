// The stock sheet in a real browser (#47): bundles main.ts, serves it with a stub API (one recorded engine
// state per run, POST /games/1/actions recorded) and drives the page with bin/shot --eval. The page script
// throws on the first failed check. Skipped without a headless browser.
import type { StockBundle } from "../types.ts";
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
    const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/#/game/1`, join(dir, "out.png"), "--width", "1440", "--height", "900", "--wait-for", ".stock-row", "--eval", checks], { stdio: "pipe" });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
  });
}


const CHECKS_SELL = (corp: string, percent: number, price: number) => String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  const posted = async () => (await (await fetch("/__posted")).json());
  if (!q(".stock-sheet")) fail("the Markt view is not the one shown");
  if (!/Markt/.test(q(".frame-tabs").textContent)) fail("no tab Markt");
  if (document.querySelectorAll(".stock-row").length < 5) fail("rows " + document.querySelectorAll(".stock-row").length);
  if (q(".frame-entry")) fail("generic bar still offers claimed actions");
  if (!/Wähle eine Aktion/.test(q(".kit-order-sentence").textContent)) fail("sentence: " + q(".kit-order-sentence").textContent);
  if (!q(".kit-main-btn").disabled) fail("main button open without a choice");
  // tablet: no target below the hit size
  const small = [...document.querySelectorAll(".stock-rowbtn, .stock-head button")].filter((b) => b.getBoundingClientRect().height < 43.5 && b.offsetParent !== null);
  if (small.length) fail("targets under 44px: " + small.map((b) => b.textContent.slice(0, 20)).join("|"));
  q('.stock-row[data-corp="${corp}"] .stock-rowbtn').click();
  await sleep(50);
  const offers = [...document.querySelectorAll(".stock-offer")];
  if (!offers.length) fail("no offers after opening the row");
  const tiny = offers.filter((b) => b.getBoundingClientRect().height < 43.5);
  if (tiny.length) fail("offer buttons under 44px");
  const sell = offers.find((b) => b.dataset.kind === "sell") || fail("no sell offer");
  sell.click();
  await sleep(50);
  if (!/${corp}: ${percent} % verkaufen, Erlös £${price}\./.test(q(".kit-order-sentence").textContent)) fail("sentence: " + q(".kit-order-sentence").textContent);
  if (q(".kit-main-btn").disabled) fail("main button locked although valid");
  if (!q('.stock-cell[data-preview="true"]')) fail("no preview cell for the price after the sale");
  if (!/Kurs/.test(q(".kit-changes").textContent)) fail("no price change line");
  if ((await posted()).length !== 0) fail("choosing sent something");
  q(".kit-main-btn").click();
  await sleep(600);
  if ((await posted()).length !== 1) fail("sent " + (await posted()).length);
})()`;

const CHECKS_PASS = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const side = document.querySelector(".frame-order-side .kit-side-btn") || fail("no pass button");
  if (!/Passen/.test(side.textContent)) fail("label " + side.textContent);
  if (side.getBoundingClientRect().height < 43.5) fail("pass button under 44px");
  side.click();
  await sleep(600);
  const p = await (await fetch("/__posted")).json();
  if (p.length !== 1) fail("pass not sent once: " + p.length);
})()`;

const CHECKS_MAP = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  document.querySelector(".stock-map").click();
  await sleep(100);
  if (document.querySelector(".stock-sheet")) fail("Karte button did not leave the sheet");
  const tab = [...document.querySelectorAll(".frame-tabs button")].find((b) => b.textContent === "Markt") || fail("tab Markt gone");
  tab.click();
  await sleep(100);
  if (!document.querySelector(".stock-sheet")) fail("tab Markt does not return to the sheet");
})()`;

async function scenario(name: string, checks: string) {
  const dir = mkdtempSync(join(tmpdir(), "oe-stock-test-"));
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

const skip = browser ? false : "no headless browser installed";

test("stock sheet in the browser: choosing a sale sends nothing, shows the price after it, the main button sends the exact action; targets are 44 px", { skip }, async () => {
  // The recording is a seeded random game: take the first sale it offers, with the money the view names for it.
  const g0 = fixture("stock-pool");
  const first = g0.state.prompt.actions.find((a: Record<string, unknown>) => a.type === "sell_shares")!;
  const b = g0.state.prompt.context!.stock!.bundles.find((x: StockBundle) => x.type === "sell_shares" && JSON.stringify(x.shares) === JSON.stringify(first.shares))!;
  const corp = b.corporation;
  const { posted, game } = await scenario("stock-pool", CHECKS_SELL(corp, b.percent, b.price));
  assert.equal(posted.length, 1);
  assert.deepEqual(posted[0]!.action, game.state.prompt.actions.find((a: Record<string, unknown>) => a.type === "sell_shares" && JSON.stringify(a.shares) === JSON.stringify(first.shares)));
  assert.equal(posted[0]!.seq, game.seq);
});

test("stock sheet in the browser: the pass button sends the offered pass", { skip }, async () => {
  const { posted, game } = await scenario("stock-pool", CHECKS_PASS);
  assert.deepEqual(posted[0]!.action, game.state.prompt.actions.find((a: Record<string, unknown>) => a.type === "pass"));
});

test("stock sheet in the browser: Karte leaves the sheet and the tab Markt returns", { skip }, async () => {
  await scenario("stock-pool", CHECKS_MAP);
});
