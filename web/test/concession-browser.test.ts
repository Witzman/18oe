// The concession panel in a real browser (#172): same stub-server approach as auction-browser.test.ts.
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
  cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
  copyFileSync(join(web, "fonts", "fonts.css"), join(dir, "fonts.css"));
  const { themesCss } = await import("../themes/css.ts");
  const { DEFAULT_THEME_ID, themes } = await import("../themes/index.ts");
  writeFileSync(join(dir, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
}

const fixture = (name: string) => JSON.parse(readFileSync(join(web, "test", "fixtures", "games", `${name}.json`), "utf8"));

function stub(dir: string, start: { seq: number }, next?: { seq: number }) {
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
      req.on("end", () => { posted.push(JSON.parse(b)); game = next ?? { ...game, seq: game.seq + 1 }; json(game); });
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
    const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/#/game/1`, join(dir, "out.png"), "--width", "1440", "--height", "900", "--wait-for", waitFor, ...(process.env.OE_THEME ? ["--theme", process.env.OE_THEME] : []), "--eval", checks], { stdio: "pipe" });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
  });
}

const HEAD = String.raw`const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s);
  const small = (sel) => { for (const e of document.querySelectorAll(sel)) { const r = e.getBoundingClientRect(); if (r.height < 43.5) fail(sel + " too small: " + r.height); } };`;

const CHECKS_FOUND = String.raw`(async () => {
  ${HEAD}
  if (document.querySelectorAll(".concession-panel .kit-ladder li").length !== 10) fail("ladder rows");
  if (q(".frame-entry")) fail("generic bar still offers the claimed actions");
  if (!q(".kit-main-btn").disabled) fail("main button open without a choice");
  const cards = document.querySelectorAll(".concession-card");
  if (cards.length < 2) fail("cards " + cards.length);
  small(".concession-card");
  q('.concession-card[data-corp="C"]').click();
  await sleep(50);
  small(".concession-price");
  q('.concession-price[data-price="90"]').click();
  await sleep(50);
  if (!/Minor C zum Kurs/.test(q(".kit-order-sentence").textContent)) fail("sentence: " + q(".kit-order-sentence").textContent);
  if ((await (await fetch("/__posted")).json()).length !== 0) fail("choosing sent something");
  q(".kit-main-btn").click();
  await sleep(600);
  if ((await (await fetch("/__posted")).json()).length !== 1) fail("not sent once");
})()`;

const CHECKS_HOME = String.raw`(async () => {
  ${HEAD}
  const t = document.querySelectorAll(".concession-target");
  if (t.length < 2) fail("targets " + t.length);
  small(".concession-target");
  if (!q(".kit-main-btn").disabled) fail("main button open without a choice");
  t[1].click();
  await sleep(50);
  if (!/Heimat in/.test(q(".kit-order-sentence").textContent)) fail("sentence: " + q(".kit-order-sentence").textContent);
  q(".kit-main-btn").click();
  await sleep(600);
  if ((await (await fetch("/__posted")).json()).length !== 1) fail("not sent once");
})()`;

async function scenario(name: string, waitFor: string, checks: string, nextName?: string) {
  const dir = mkdtempSync(join(tmpdir(), "oe-concession-test-"));
  try {
    await bundle(dir);
    const game = fixture(name);
    const { server, posted } = stub(dir, game, nextName ? fixture(nextName) : undefined);
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const code = await run(dir, (server.address() as { port: number }).port, waitFor, checks);
    if (process.env.OE_SHOT_DIR) copyFileSync(join(dir, "out.png"), join(process.env.OE_SHOT_DIR, `${name}-${process.env.OE_THEME ?? "default"}.png`));
    server.closeAllConnections();
    server.close();
    assert.equal(code, 0, "page checks failed (see stderr)");
    return { posted, game };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test("concession in the browser: card and par value choose, the main button sends exactly the offered par action", { skip: browser ? false : "no headless browser installed" }, async () => {
  const { posted, game } = await scenario("concession-minor", ".concession-card", CHECKS_FOUND);
  assert.equal(posted.length, 1);
  assert.deepEqual(posted[0]!.action, game.state.prompt.actions.find((a: Record<string, unknown>) => a.type === "par" && a.corporation === "C" && String(a.share_price).startsWith("90,")));
  assert.equal(posted[0]!.seq, game.seq);
});

test("concession in the browser: home token target chosen from the list is sent as the offered place_token", { skip: browser ? false : "no headless browser installed" }, async () => {
  const { posted, game } = await scenario("home-token", ".concession-target", CHECKS_HOME);
  assert.equal(posted.length, 1);
  assert.deepEqual(posted[0]!.action, game.state.prompt.actions.filter((a: Record<string, unknown>) => a.type === "place_token")[1]);
});

// #289: the owner's live game hung after "Witzman executes the 1st Concession" (DSJ parred at 60): nothing
// could be clicked. Recorded over the real API (bin: seed 2, Witzman + 3 bots, see the PR): Witzman holds the
// 2nd concession too, so the answer to the par is again a Concession prompt for him. Cause: the busy lock of
// the frame disabled every button while the action was in flight, the panel redrew inside the lock and its
// fresh buttons were never opened again (no further seq change, because nobody else moves).
const CHECKS_CHAIN = String.raw`(async () => {
  ${HEAD}
  const posted = async () => (await (await fetch("/__posted")).json()).length;
  q('.concession-card[data-corp="DSJ"]').click();
  await sleep(50);
  q('.concession-price[data-price="60"]').click();
  await sleep(50);
  q(".kit-main-btn").click();
  for (let i = 0; i < 60 && ((await posted()) !== 1 || q(".frame[aria-busy]")); i++) await sleep(50);
  await sleep(200);
  if (document.querySelectorAll("button[data-busy-lock]").length) fail("buttons still locked after the answer");
  if (!q(".frame-stall").hidden) fail("stall notice shown although the viewer can act: " + q(".frame-stall").textContent);
  const cards = [...document.querySelectorAll(".concession-card")];
  if (cards.length < 2) fail("no offers after the 1st concession");
  if (cards.some((c) => c.disabled)) fail("offers of the 2nd concession are disabled");
  q('.concession-card[data-corp="LNWR"]').click();
  await sleep(50);
  if (q('.concession-card[data-corp="LNWR"]').getAttribute("aria-pressed") !== "true") fail("card click had no effect");
  const price = [...document.querySelectorAll(".concession-price")].find((b) => !b.disabled);
  if (!price) fail("no enabled par value for LNWR");
  price.click();
  await sleep(50);
  if (q(".kit-main-btn").disabled) fail("main button closed after a choice: " + q(".kit-order-sentence")?.textContent);
  q(".kit-main-btn").click();
  for (let i = 0; i < 60 && (await posted()) !== 2; i++) await sleep(50);
  if ((await posted()) !== 2) fail("2nd founding not sent");
})()`;

test("concession in the browser (#289): after the 1st concession the same viewer's 2nd concession can be founded", { skip: browser ? false : "no headless browser installed" }, async () => {
  const { posted } = await scenario("concession-chain", ".concession-card", CHECKS_CHAIN, "concession-chain-next");
  assert.equal(posted.length, 2);
  const next = fixture("concession-chain-next");
  assert.equal(posted[1]!.seq, next.seq);
  assert.equal(posted[1]!.action.corporation, "LNWR");
});
