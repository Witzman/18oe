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
  if (!/Market/.test(q(".frame-tabs").textContent)) fail("no tab Market");
  if (document.querySelectorAll(".stock-row").length < 5) fail("rows " + document.querySelectorAll(".stock-row").length);
  if ([...document.querySelectorAll(".frame-entry")].some((e) => ["buy_shares", "sell_shares", "par", "pass"].includes(e.dataset.type))) fail("generic bar still offers claimed actions");
  if (q(".kit-dialog")) fail("a dialog is open before any choice");
  // tablet: no target below the hit size
  const small = [...document.querySelectorAll(".stock-rowbtn, .stock-head button, .stock-hold")].filter((b) => b.getBoundingClientRect().height < 43.5 && b.offsetParent !== null);
  if (small.length) fail("targets under 44px: " + small.map((b) => b.textContent.slice(0, 20)).join("|"));
  q('.stock-hold[data-corp="${corp}"]').click();
  await sleep(50);
  const dlg = q(".kit-dialog") || fail("no dialog after choosing a share");
  if (!new RegExp("${corp}").test(dlg.querySelector("h3").textContent)) fail("title " + dlg.querySelector("h3").textContent);
  const offers = [...dlg.querySelectorAll(".stock-offer")];
  if (!offers.length) fail("no offers in the dialog");
  if (offers.some((b) => b.dataset.kind !== "sell")) fail("the sale dialog offers something else");
  const tiny = [...dlg.querySelectorAll("button")].filter((b) => b.getBoundingClientRect().height < 43.5);
  if (tiny.length) fail("dialog buttons under 44px");
  if (dlg.querySelector(".kit-main-btn")) fail("an order before the choice");
  offers.find((b) => b.dataset.kind === "sell").click();
  await sleep(50);
  const sentence = q(".kit-dialog .kit-order-sentence") || fail("no order in the dialog");
  if (!/${corp}: sell ${percent} %, proceeds £${price}\./.test(sentence.textContent)) fail("sentence: " + sentence.textContent);
  if (q(".kit-dialog .kit-main-btn").disabled) fail("main button locked although valid");
  if (!q('.stock-cell[data-preview="true"]')) fail("no preview cell for the price after the sale");
  if (!/Cash/.test(q(".kit-dialog .kit-changes").textContent)) fail("no cash change line");
  if ((await posted()).length !== 0) fail("choosing sent something");
  q(".kit-dialog .kit-main-btn").click();
  await sleep(600);
  if ((await posted()).length !== 1) fail("sent " + (await posted()).length);
})()`;

const CHECKS_CLOSE = (corp: string) => String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  q('.stock-hold[data-corp="${corp}"]').click();
  await sleep(50);
  if (!q(".kit-dialog")) fail("no dialog");
  q(".kit-dialog .stock-offer").click();
  await sleep(50);
  ([...q(".kit-dialog").querySelectorAll("button")].find((b) => b.textContent === "Cancel") || fail("no Cancel once an offer is chosen")).click();
  await sleep(50);
  if (q(".kit-dialog")) fail("Cancel did not close the dialog");
  q('.stock-hold[data-corp="${corp}"]').click();
  await sleep(50);
  q(".kit-backdrop").dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  await sleep(50);
  if (q(".kit-dialog")) fail("Escape did not close the dialog");
  if ((await (await fetch("/__posted")).json()).length !== 0) fail("closing sent something");
})()`;

const CHECKS_BUY = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  const tabs = [...document.querySelectorAll('.stock-tabs [role="tab"]')].map((t) => t.textContent);
  if (tabs.join("|") !== "Stock market|Open Market") fail("tabs " + tabs);
  let offers = [];
  for (const row of [...document.querySelectorAll(".stock-row")].filter((r) => r.dataset.actionable === "true")) {
    row.querySelector(".stock-rowbtn").click();
    await sleep(50);
    if (!q(".kit-dialog")) fail("no dialog after clicking a corporation");
    offers = [...q(".kit-dialog").querySelectorAll(".stock-offer")];
    if (offers.length) break;
    q(".kit-backdrop").dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    await sleep(50);
  }
  if (!offers.length) fail("no corporation offers anything to buy");
  if (offers.some((b) => b.dataset.kind === "sell")) fail("the buy dialog offers a sale");
  if (offers.some((b) => b.dataset.kind === "buy" && /Open Market,/.test(b.textContent))) fail("market shares in the Aktienmarkt tab");
  q(".kit-backdrop").dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  await sleep(50);
  document.querySelector('.stock-tabs [data-tab="market"]').click();
  await sleep(50);
  const rows = [...document.querySelectorAll(".stock-row")];
  if (!rows.length) fail("Open Market lists no corporation");
  if (rows.some((r) => !/Open Market \d+/.test(r.textContent))) fail("a corporation without market shares in the Open Market tab");
})()`;

// Pass is a kind of the action box without options (#497 S3): step 1 button, then the one entry, then the main button.
const CHECKS_PASS = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  if (document.querySelector('.stock-head [data-action="pass"]')) fail("the head still has a pass button");
  const kind = document.querySelector('.frame-kind[data-kind="pass"]') || fail("no kind Passen in step 1");
  if (!/Pass \(1\)/.test(kind.textContent)) fail("label " + kind.textContent);
  if (kind.getBoundingClientRect().height < 43.5) fail("kind button under 44px");
  kind.click();
  await sleep(50);
  const entry = document.querySelector('.frame-entry[data-type="pass"]') || fail("no pass entry in step 2");
  entry.click();
  await sleep(50);
  const main = document.querySelector(".frame-panel .kit-main-btn") || fail("no main button");
  main.click();
  await sleep(600);
  const p = await (await fetch("/__posted")).json();
  if (p.length !== 1) fail("pass not sent once: " + p.length);
})()`;

// The box leads by kind, the sheet follows it (#497 S3): buy shows only cards with a purchase, the box lists them, back shows all.
const CHECKS_BOX = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s), qa = (s) => [...document.querySelectorAll(s)];
  const all = qa(".stock-row").length;
  const kinds = qa(".frame-kind").map((b) => b.dataset.kind);
  for (const k of ["buy", "sell", "pass"]) if (!kinds.includes(k)) fail("step 1 lacks the kind " + k + ": " + kinds);
  if (qa(".frame-option").length) fail("options before a kind is chosen");
  if (qa(".frame-kind").some((b) => b.getBoundingClientRect().height < 43.5)) fail("a kind button under 44px");
  q('.frame-kind[data-kind="buy"]').click();
  await sleep(100);
  if (qa(".frame-kind").length) fail("other kinds still visible in step 2");
  const opts = qa(".frame-option");
  if (!opts.length) fail("no corporation in the box");
  if (opts.some((b) => b.getBoundingClientRect().height < 43.5)) fail("an option under 44px");
  const rows = qa(".stock-row");
  if (rows.length !== opts.length) fail("cards " + rows.length + " vs box " + opts.length);
  if (!q(".stock-sheet")) fail("the sheet is not shown for the kind");
  if (q('.stock-hold')) fail("holdings are offered while buying");
  opts[0].click();
  await sleep(100);
  const dlg = q(".kit-dialog") || fail("an option of the box opens no dialog");
  if (dlg.querySelector('.stock-offer:not([data-kind="buy"])')) fail("the dialog offers more than the kind");
  q(".kit-dialog .kit-side-btn").click();
  await sleep(100);
  if (q(".kit-dialog")) fail("closing the dialog left it open");
  if (!qa(".frame-option").length) fail("closing the dialog left the kind (Cancel is not Back)");
  q(".frame-kind-back").click();
  await sleep(100);
  if (qa(".stock-row").length !== all) fail("back did not show all cards again");
  if (!qa(".frame-kind").length) fail("back did not show step 1");
})()`;

const CHECKS_MAP = String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const tabs = () => [...document.querySelectorAll(".frame-tabs button")];
  (tabs().find((b) => b.textContent === "Map") || fail("no tab Map")).click();
  await sleep(100);
  if (document.querySelector(".stock-sheet")) fail("the tab Map did not leave the sheet");
  (tabs().find((b) => b.textContent === "Market") || fail("tab Market gone")).click();
  await sleep(100);
  if (!document.querySelector(".stock-sheet")) fail("tab Market does not return to the sheet");
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

test("stock sheet in the browser: the box leads by kind, the sheet shows only that kind's cards, back shows all", { skip }, async () => {
  await scenario("stock-pool", CHECKS_BOX);
});

test("stock sheet in the browser: the box's kind Passen sends the offered pass", { skip }, async () => {
  const { posted, game } = await scenario("stock-pool", CHECKS_PASS);
  assert.deepEqual(posted[0]!.action, game.state.prompt.actions.find((a: Record<string, unknown>) => a.type === "pass"));
});

test("stock sheet in the browser: the tab Karte leaves the sheet and the tab Markt returns", { skip }, async () => {
  await scenario("stock-pool", CHECKS_MAP);
});

test("stock sheet in the browser: Abbrechen and Escape close the dialog without sending", { skip }, async () => {
  const g0 = fixture("stock-pool");
  const first = g0.state.prompt.actions.find((a: Record<string, unknown>) => a.type === "sell_shares")!;
  const b = g0.state.prompt.context!.stock!.bundles.find((x: StockBundle) => x.type === "sell_shares" && JSON.stringify(x.shares) === JSON.stringify(first.shares))!;
  const { posted } = await scenario("stock-pool", CHECKS_CLOSE(b.corporation));
  assert.equal(posted.length, 0);
});

test("stock sheet in the browser: a corporation opens the buy dialog; the tabs Aktienmarkt and Open Market list their own corporations", { skip }, async () => {
  const { posted } = await scenario("stock-pool", CHECKS_BUY);
  assert.equal(posted.length, 0);
});
