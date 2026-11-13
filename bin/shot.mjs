// Screenshot tool (#42): renders a URL or a local file with a headless Chromium and writes a PNG.
// Dependencies: none for Chromium (speaks the DevTools protocol over a WebSocket itself; Node 22 has WebSocket built in).
// Usage: see bin/shot --help. The browser is the Debian package chromium-headless-shell (or $OE_BROWSER).
import { createRequire } from "node:module";
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { basename, dirname, extname, join, resolve } from "node:path";

const USAGE = `bin/shot <url|file> <out.png> [--width N] [--height N] [--theme brett|atlas]
         [--device ipad|ipad-10.2] [--orientation landscape|portrait] [--engine auto|chromium|webkit]
         [--tile-style full|inner] [--wait-for <css selector>] [--delay ms] [--eval <js>]
  url    http(s) URL, including a #hash route (e.g. http://127.0.0.1:4567/#/kit)
  file   local HTML file; its directory is served as site root on 127.0.0.1 (module scripts
         and root-absolute paths like /main.js work, e.g. web/dist/index.html#/kit)
  --theme       sets localStorage oe.theme before the page runs
  --tile-style  sets localStorage oe.tileStyle
  --wait-for    waits (max 15 s) until the selector matches
  --delay       extra wait in ms after load (default 300)
  --eval        JS run in the page after load/wait-for, before the shot (e.g. to set state)
  --full-page   capture the whole scroll height, not just the viewport
  --device      iPad profile (#260): viewport, devicePixelRatio, mobile, touch, iPad user agent.
                ipad = iPad Pro 11 (834x1194), ipad-10.2 = iPad gen 7 (810x1080); portrait numbers,
                landscape swaps them. Overrides --width/--height.
  --orientation landscape (default) or portrait, with --device
  --engine      webkit = real Playwright WebKit (needs .tools/pw, see README; fails if the host lacks
                its system libraries); chromium = Chromium with the iPad profile, an APPROXIMATION
                (no Safari behaviour); auto (default) = webkit if it starts, else chromium, and says so.
  Touch in --eval (Chromium engine): await window.oeTouch("start"|"move"|"end", [{x,y,id?}, ...]) sends
  real touch input via the DevTools protocol; in the WebKit engine only window.oeTouch("tap", [{x,y}]).
Locking: every run takes the machine-wide lock tmp/heavy.lock (flock) of the main 18oe checkout, so
  at most one browser runs at a time; set OE_HEAVY_LOCK_HELD=1 if the caller already holds it.
Browser: $OE_BROWSER, else chromium-headless-shell / chromium on PATH or /usr/bin.`;

export const MIME = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css",
  ".json": "application/json", ".woff2": "font/woff2", ".woff": "font/woff", ".png": "image/png",
  ".svg": "image/svg+xml", ".map": "application/json", ".jpg": "image/jpeg", ".webp": "image/webp" };

// iPad profiles, portrait numbers as in Playwright's device list (playwright-core 1.65): CSS viewport, DPR.
export const IPAD_UA = "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1";
export const DEVICES = {
  "ipad": { playwright: "iPad Pro 11", width: 834, height: 1194, dpr: 2 },
  "ipad-10.2": { playwright: "iPad (gen 7)", width: 810, height: 1080, dpr: 2 },
};

export function resolveDevice(o) {
  if (!o.device) return null;
  const d = DEVICES[o.device];
  if (!d) throw new Error(`unknown --device ${o.device} (known: ${Object.keys(DEVICES).join(", ")})`);
  if (!["landscape", "portrait"].includes(o.orientation)) throw new Error("--orientation needs landscape or portrait");
  const land = o.orientation === "landscape";
  return { ...d, width: land ? d.height : d.width, height: land ? d.width : d.height,
    playwright: land ? `${d.playwright} landscape` : d.playwright, ua: IPAD_UA };
}

export function parseArgs(argv) {
  const opts = { device: null, orientation: "landscape", engine: "auto", width: 1280, height: 800, delay: 300, theme: null, tileStyle: null, waitFor: null, evalJs: null, fullPage: false };
  const pos = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) throw new Error(`${a} needs a value`); return argv[++i]; };
    if (a === "--width") opts.width = Number(val());
    else if (a === "--height") opts.height = Number(val());
    else if (a === "--delay") opts.delay = Number(val());
    else if (a === "--theme") opts.theme = val();
    else if (a === "--tile-style") opts.tileStyle = val();
    else if (a === "--wait-for") opts.waitFor = val();
    else if (a === "--eval") opts.evalJs = val();
    else if (a === "--device") opts.device = val();
    else if (a === "--orientation") opts.orientation = val();
    else if (a === "--engine") opts.engine = val();
    else if (a === "--full-page") opts.fullPage = true;
    else if (a === "-h" || a === "--help") opts.help = true;
    else if (a.startsWith("--")) throw new Error(`unknown option ${a}`);
    else pos.push(a);
  }
  [opts.width, opts.height, opts.delay].forEach((n) => { if (!Number.isFinite(n) || n < 0) throw new Error("--width/--height/--delay need numbers"); });
  if (!["auto", "chromium", "webkit"].includes(opts.engine)) throw new Error("--engine needs auto, chromium or webkit");
  [opts.input, opts.out] = pos;
  return opts;
}

export function findBrowser(env = process.env) {
  if (env.OE_BROWSER) return env.OE_BROWSER;
  for (const dir of [...(env.PATH ?? "").split(":"), "/usr/bin"]) {
    for (const name of ["chromium-headless-shell", "chromium"]) {
      const p = join(dir, name);
      if (dir && existsSync(p)) return p;
    }
  }
  return null;
}

function serveDir(dir) {
  const server = createServer((req, res) => {
    const path = decodeURIComponent((req.url ?? "/").split("?")[0]);
    const file = resolve(dir, "." + path);
    if (!file.startsWith(dir) || !existsSync(file) || !statSync(file).isFile()) { res.writeHead(404).end("not found"); return; }
    res.writeHead(200, { "content-type": MIME[extname(file)] ?? "application/octet-stream" }).end(readFileSync(file));
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok(server)));
}

// Machine-wide lock (flock): at most one heavy job (browser) at a time across all agents. The lock file is
// tmp/heavy.lock of the MAIN checkout (worktrees share it). Re-executes this script under flock.
export function lockFile() {
  const git = spawnSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd: dirname(fileURLToPath(import.meta.url)), encoding: "utf8" });
  const common = git.status === 0 ? git.stdout.trim() : null;
  return common ? join(dirname(common), "tmp", "heavy.lock") : null;
}
async function takeLock() {
  if (process.env.OE_HEAVY_LOCK_HELD) return;
  const lock = lockFile();
  if (!lock) return;
  mkdirSync(dirname(lock), { recursive: true });
  const r = spawnSync("flock", [lock, process.execPath, ...process.argv.slice(1)], { stdio: "inherit", env: { ...process.env, OE_HEAVY_LOCK_HELD: "1" } });
  process.exit(r.status ?? 1);
}

// Real WebKit through playwright-core in .tools/pw (see README). Returns true when the shot was taken.
// With required=false a failure to start returns false so the caller falls back to Chromium.
async function shotWebkit(o, dev, url, required) {
  const pw = resolve(dirname(fileURLToPath(import.meta.url)), "..", ".tools", "pw");
  let browser;
  try {
    process.env.PLAYWRIGHT_BROWSERS_PATH ??= join(pw, "browsers");
    const { webkit, devices } = createRequire(join(pw, "x.js"))("playwright-core");
    browser = await webkit.launch();
    const ctx = await browser.newContext({ ...devices[dev.playwright] });
    const page = await ctx.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
    await page.exposeFunction("oeTouchRaw", async (json) => { const { type, pts } = JSON.parse(json); if (type === "tap") await page.touchscreen.tap(pts[0].x, pts[0].y); else throw new Error(`oeTouch(${type}) is Chromium-engine only`); });
    await page.addInitScript(`window.oeTouch = (type, pts) => window.oeTouchRaw(JSON.stringify({ type, pts }));`);
    const seed = [];
    if (o.theme) seed.push(`localStorage.setItem("oe.theme", ${JSON.stringify(o.theme)})`);
    if (o.tileStyle) seed.push(`localStorage.setItem("oe.tileStyle", ${JSON.stringify(o.tileStyle)})`);
    if (seed.length) await page.addInitScript(`try { ${seed.join("; ")}; } catch (e) {}`);
    await page.goto(url, { waitUntil: "load", timeout: 30000 });
    if (o.waitFor) await page.waitForSelector(o.waitFor, { timeout: 15000 });
    await page.evaluate("document.fonts.ready.then(() => true)");
    if (o.evalJs) await page.evaluate(o.evalJs);
    await page.waitForTimeout(o.delay);
    await page.screenshot({ path: o.out, fullPage: o.fullPage });
    errors.slice(0, 5).forEach((e) => console.error(`page error: ${e}`));
    console.log(`${o.out} (${dev.width}x${dev.height}@${dev.dpr}x ${o.device} ${o.orientation} WEBKIT) from ${url}`);
    return true;
  } catch (e) {
    if (required) throw new Error(`webkit engine failed: ${String(e.message).split("\n").slice(0, 3).join(" ")}`);
    console.error(`bin/shot: real WebKit not available (${String(e.message).split("\n")[0].slice(0, 140)}); see README "iPad profile"`);
    return false;
  } finally { await browser?.close().catch(() => {}); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const o = parseArgs(process.argv.slice(2));
  if (o.help || !o.input || !o.out) { console.log(USAGE); process.exit(o.help ? 0 : 2); }
  await takeLock();
  const dev = resolveDevice(o);
  if (dev) { o.width = dev.width; o.height = dev.height; }
  const browser = findBrowser();
  if (!browser) { console.error("bin/shot: no browser found (apt: chromium-headless-shell; or set OE_BROWSER)"); process.exit(3); }

  let server = null;
  let url = o.input;
  if (!/^https?:\/\//.test(url)) {
    const [path, hash] = url.split(/(?=#)/);
    const file = resolve(path);
    if (!existsSync(file)) throw new Error(`not found: ${path}`);
    server = await serveDir(dirname(file));
    url = `http://127.0.0.1:${server.address().port}/${basename(file)}${hash ?? ""}`;
  }

  if (dev && o.engine !== "chromium") {
    const done = await shotWebkit(o, dev, url, o.engine === "webkit");
    if (done) { server?.close(); return; }
  }
  if (dev) console.error(`bin/shot: iPad profile on CHROMIUM = approximation (viewport ${dev.width}x${dev.height} @${dev.dpr}x, touch, iPad UA); no Safari behaviour`);

  const profile = mkdtempSync(join(tmpdir(), "oe-shot-"));
  const child = spawn(browser, ["--no-sandbox", "--disable-gpu", "--enable-unsafe-swiftshader", "--hide-scrollbars",
    "--remote-debugging-port=0", `--user-data-dir=${profile}`, `--window-size=${o.width},${o.height}`, "about:blank"],
  { env: { ...process.env, HOME: profile, XDG_CONFIG_HOME: profile, XDG_CACHE_HOME: profile }, stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  const port = await new Promise((ok, fail) => {
    const t = setTimeout(() => fail(new Error(`browser did not start:\n${stderr.slice(-800)}`)), 20000);
    child.stderr.on("data", (d) => {
      stderr += d;
      const m = /DevTools listening on ws:\/\/[^:]+:(\d+)\//.exec(stderr);
      if (m) { clearTimeout(t); ok(Number(m[1])); }
    });
    child.on("exit", (c) => fail(new Error(`browser exited (${c}):\n${stderr.slice(-800)}`)));
  });

  try {
    let targets = [];
    for (let i = 0; i < 50 && !targets.length; i++) {
      targets = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).filter((t) => t.type === "page");
      if (!targets.length) await sleep(100);
    }
    const ws = new WebSocket(targets[0].webSocketDebuggerUrl);
    await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = () => fail(new Error("devtools connect failed")); });
    let id = 0;
    const pending = new Map();
    const listeners = [];
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && pending.has(m.id)) { const { ok, fail } = pending.get(m.id); pending.delete(m.id); m.error ? fail(new Error(m.error.message)) : ok(m.result); }
      else listeners.forEach((l) => l(m));
    };
    const send = (method, params = {}) => new Promise((ok, fail) => { pending.set(++id, { ok, fail }); ws.send(JSON.stringify({ id, method, params })); });
    const evaluate = async (expression) => {
      const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
      if (r.exceptionDetails) throw new Error(`page script failed: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
      return r.result.value;
    };
    const consoleErrors = [];
    listeners.push((m) => {
      if (m.method === "Runtime.exceptionThrown") consoleErrors.push(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text);
      if (m.method === "Runtime.consoleAPICalled" && m.params.type === "error") consoleErrors.push(m.params.args.map((a) => a.value ?? a.description).join(" "));
    });

    await send("Page.enable");
    await send("Runtime.enable");
    await send("Emulation.setDeviceMetricsOverride", { width: o.width, height: o.height, deviceScaleFactor: dev?.dpr ?? 1, mobile: !!dev });
    if (dev) {
      await send("Emulation.setUserAgentOverride", { userAgent: dev.ua, platform: "iPad" });
      await send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 });
      await send("Runtime.addBinding", { name: "oeTouchRaw" });
      await send("Page.addScriptToEvaluateOnNewDocument", { source: `window.oeTouch = (type, pts) => new Promise((ok) => { window.__oeTouchDone = ok; window.oeTouchRaw(JSON.stringify({ type, pts })); });` });
      listeners.push(async (m) => {
        if (m.method !== "Runtime.bindingCalled" || m.params.name !== "oeTouchRaw") return;
        const { type, pts } = JSON.parse(m.params.payload);
        const touchPoints = pts.map((p, i) => ({ x: p.x, y: p.y, id: p.id ?? i }));
        const t = { start: "touchStart", move: "touchMove", end: "touchEnd" }[type];
        await send("Input.dispatchTouchEvent", { type: t, touchPoints: type === "end" ? [] : touchPoints });
        await send("Runtime.evaluate", { expression: "window.__oeTouchDone && window.__oeTouchDone()" });
      });
    }
    const seed = [];
    if (o.theme) seed.push(`localStorage.setItem("oe.theme", ${JSON.stringify(o.theme)})`);
    if (o.tileStyle) seed.push(`localStorage.setItem("oe.tileStyle", ${JSON.stringify(o.tileStyle)})`);
    if (seed.length) await send("Page.addScriptToEvaluateOnNewDocument", { source: `try { ${seed.join("; ")}; } catch (e) {}` });

    const loaded = new Promise((ok) => listeners.push((m) => { if (m.method === "Page.loadEventFired") ok(); }));
    await send("Page.navigate", { url });
    await Promise.race([loaded, sleep(30000).then(() => { throw new Error("page load timeout"); })]);
    if (o.waitFor) {
      const sel = JSON.stringify(o.waitFor);
      let found = false;
      for (let i = 0; i < 150 && !found; i++) { found = await evaluate(`!!document.querySelector(${sel})`); if (!found) await sleep(100); }
      if (!found) throw new Error(`--wait-for ${o.waitFor}: not found within 15 s`);
    }
    await evaluate("document.fonts.ready.then(() => true)");
    if (o.evalJs) await evaluate(o.evalJs);
    await sleep(o.delay);
    const params = { format: "png" };
    if (o.fullPage) {
      const h = await evaluate("Math.ceil(document.documentElement.scrollHeight)");
      params.clip = { x: 0, y: 0, width: o.width, height: h, scale: 1 };
      params.captureBeyondViewport = true;
    }
    const shot = await send("Page.captureScreenshot", params);
    writeFileSync(o.out, Buffer.from(shot.data, "base64"));
    consoleErrors.slice(0, 5).forEach((e) => console.error(`page error: ${e}`));
    console.log(`${o.out} (${o.width}x${o.height}${dev ? `@${dev.dpr}x ${o.device} ${o.orientation} chromium-approximation` : ""}${o.fullPage ? "+" : ""}) from ${url}`);
    ws.close();
  } finally {
    child.kill("SIGKILL");
    server?.close();
    rmSync(profile, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then(() => process.exit(0), (e) => { console.error(`bin/shot: ${e.message}`); process.exit(1); });
}
