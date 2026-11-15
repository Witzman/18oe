// iPad-10.2 acceptance shots in CI (#304). Not a test: run by .github/workflows/shots.yml after `npm run build`.
// Per scene (= game fixture), orientation and panel mode: one plain screenshot first (wait for body only), then a
// separate measurement run with its own timeout. Every browser run has a hard timeout; a failing run is noted in
// report.json and the loop goes on. Usage: node test/ci-shots.mjs <outDir> [scene,scene,...]
// Env: OE_BROWSER (headless Chrome wrapper), SHOT_TIMEOUT_MS (default 60000), ORIENTS, MODES, WORKERS (default 3).
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join } from "node:path";
import { spawn } from "node:child_process";

const web = new URL("..", import.meta.url).pathname;
const dist = join(web, "dist");
const shot = new URL("../../bin/shot.mjs", import.meta.url).pathname;
const OUT = process.argv[2];
const only = process.argv[3] ? process.argv[3].split(",") : null;
const TIMEOUT = Number(process.env.SHOT_TIMEOUT_MS || 60000);
const MIME = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".json": "application/json", ".woff2": "font/woff2", ".map": "application/json" };
if (!OUT) { console.error("usage: node test/ci-shots.mjs <outDir> [scenes]"); process.exit(2); }
mkdirSync(OUT, { recursive: true });

function startServer() {
  const st = { game: null, report: null };
  const server = createServer((req, res) => {
    const p = new URL(req.url, "http://x").pathname;
    const json = (o, code = 200) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(o)); };
    if (p === "/me") return json({ id: "p0", name: "p0" });
    if (p === "/games/1") return json(st.game);
    if (p === "/games/1/version") return json({ seq: st.game.seq, status: "active" });
    if (p === "/games/1/actions") return json(st.game);
    if (p === "/__report") { let b = ""; req.on("data", (c) => { b += c; }); req.on("end", () => { st.report = b; json({}); }); return; }
    const f = join(dist, p === "/" ? "index.html" : p);
    if (existsSync(f) && f.startsWith(dist)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); }
    else { res.writeHead(404); res.end(); }
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok({ server, st, port: server.address().port })));
}

// Runs in the page; always posts a report, even on its own failure.
const EVAL = (collapse) => `(async () => {
  const post = async (o) => { try { await fetch("/__report", { method: "POST", body: JSON.stringify(o) }); } catch (e) { console.error("report post failed " + e); } };
  try {
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    for (let i = 0; i < 60 && !document.querySelector(".frame-panel"); i++) await sleep(100);
    const panel = document.querySelector(".frame-panel");
    const panelFound = !!panel;
    ${collapse ? 'const tg = document.querySelector(".frame-panel-toggle"); const toggleFound = !!tg; if (tg) tg.click(); await sleep(500);' : 'const toggleFound = !!document.querySelector(".frame-panel-toggle"); await sleep(200);'}
    const vw = innerWidth, vh = innerHeight;
    const vis = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none"; };
    const small = [];
    for (const e of document.querySelectorAll("button,a[href],input,select,textarea,[role=button],[role=tab],.op-opt,.stock-row")) {
      if (!vis(e)) continue; const r = e.getBoundingClientRect();
      if (r.height < 43.5 || r.width < 43.5) small.push((e.className || e.tagName) + " " + Math.round(r.width) + "x" + Math.round(r.height) + " '" + (e.textContent || "").trim().slice(0, 20) + "'");
    }
    const pr = panel && panel.getBoundingClientRect();
    const main = document.querySelector(".kit-main-btn"); let mainInfo = null;
    if (main && vis(main)) { const r = main.getBoundingClientRect(); const top = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
      mainInfo = { rect: [r.x, r.y, r.width, r.height].map(Math.round), reachable: !!(top && (main === top || main.contains(top) || (top.closest && top.closest(".kit-main-btn")))), disabled: main.disabled }; }
    const sel = [...document.querySelectorAll("[aria-pressed=true],[aria-selected=true],.is-selected,.selected,.sel")].filter(vis).map((e) => {
      const r = e.getBoundingClientRect(); const t = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
      const cs = getComputedStyle(e);
      return { el: String(e.className || e.tagName).slice(0, 40), inView: r.bottom <= vh && r.top >= 0 && r.right <= vw && r.left >= 0, onTop: !!(t && (t === e || e.contains(t))), color: cs.color, bg: cs.backgroundColor, text: (e.textContent || "").trim().slice(0, 20) };
    });
    const body = document.querySelector(".frame-panel-body");
    await post({ ok: true, vw, vh, docW: document.documentElement.scrollWidth, hScroll: document.documentElement.scrollWidth > vw + 1,
      panelFound, toggleFound, collapsed: panel && panel.dataset.collapsed, panel: pr && [pr.x, pr.y, pr.width, pr.height].map(Math.round),
      panelOutside: pr ? (pr.bottom > vh + 1 || pr.right > vw + 1 || pr.left < -1 || pr.top < -1) : null,
      bodyScrolls: body ? body.scrollHeight > body.clientHeight + 1 : null, small, mainInfo, sel,
      step: (document.querySelector(".frame-panel-step") || {}).textContent || null });
  } catch (e) { await post({ ok: false, error: String(e && e.stack || e) }); }
})()`;

function run(args, ms) {
  return new Promise((ok) => {
    const child = spawn(process.execPath, [shot, ...args], { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, OE_HEAVY_LOCK_HELD: "1" }, detached: true });
    let err = "", out = ""; let timedOut = false;
    child.stderr.on("data", (d) => { err += d; }); child.stdout.on("data", (d) => { out += d; });
    const t = setTimeout(() => { timedOut = true; try { process.kill(-child.pid, "SIGKILL"); } catch {} }, ms);
    child.on("close", (code) => { clearTimeout(t); ok({ code, timedOut, err, out }); });
  });
}

const fixtures = readdirSync(join(web, "test/fixtures/games")).map((f) => f.replace(".json", "")).filter((f) => !only || only.includes(f));
const jobs = [];
for (const orient of (process.env.ORIENTS || "landscape,portrait").split(",")) for (const name of fixtures) for (const mode of (process.env.MODES || "open,collapsed").split(",")) jobs.push({ name, orient, mode });
const rows = [];

async function worker() {
  const { server, st, port } = await startServer();
  const url = `http://127.0.0.1:${port}/#/game/1`;
  for (let j; (j = jobs.shift());) {
    const { name, orient, mode } = j;
    const base = ["--device", "ipad-10.2", "--orientation", orient, "--engine", "chromium", "--wait-for", "body", "--delay", "2500"];
    const png = join(OUT, `${name}-${orient}-${mode}.png`);
    const row = { name, orient, mode };
    st.game = JSON.parse(readFileSync(join(web, `test/fixtures/games/${name}.json`), "utf8"));
    if (mode === "open") {
      const a = await run([url, png, ...base], TIMEOUT);
      row.shot = { code: a.code, timedOut: a.timedOut, errors: [...a.err.matchAll(/page error: (.*)/g)].map((m) => m[1].slice(0, 300)) };
      if (a.code !== 0 && !a.timedOut) row.shot.stderr = a.err.slice(-300);
    }
    st.report = null;
    const mpng = mode === "open" ? join(OUT, `.m-${name}-${orient}.png`) : png;
    const b = await run([url, mpng, ...base, "--eval", EVAL(mode === "collapsed")], TIMEOUT);
    row.measure = { code: b.code, timedOut: b.timedOut, pageErrors: [...b.err.matchAll(/page error: (.*)/g)].map((m) => m[1].slice(0, 300)) };
    if (b.code !== 0 && !b.timedOut) row.measure.stderr = b.err.slice(-300);
    if (st.report) { try { Object.assign(row.measure, JSON.parse(st.report)); } catch (e) { row.measure.reportParse = String(e); } } else row.measure.noReport = true;
    if (mode === "open") rmSync(mpng, { force: true });
    rows.push(row);
    console.log(JSON.stringify(row).slice(0, 600));
    writeFileSync(join(OUT, "report.json"), JSON.stringify(rows, null, 1));
  }
  server.closeAllConnections(); server.close();
}

await Promise.all(Array.from({ length: Number(process.env.WORKERS || 3) }, worker));
rows.sort((a, b) => (a.orient + a.name + a.mode).localeCompare(b.orient + b.name + b.mode));
writeFileSync(join(OUT, "report.json"), JSON.stringify(rows, null, 1));
console.log(`done: ${rows.length} runs, shots missing ${rows.filter((r) => r.mode === "open" ? r.shot.code !== 0 : r.measure.code !== 0).length}, no report ${rows.filter((r) => r.measure.noReport).length}`);
process.exit(0);
