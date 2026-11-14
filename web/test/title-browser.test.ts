// Titel- und Anmeldebildschirm im Browser (#280): Formular sofort bedienbar (Felder >= 44 px, nicht von der
// Szene verdeckt), Versionsfuß bleibt, Animation läuft, statischer Fall (data-still / prefers-reduced-motion).
// Ohne Browser übersprungen. bin/shot kann prefers-reduced-motion nicht emulieren: der CSS-Block wird
// deshalb in den Stylesheets geprüft und der Fall data-still (Theme-Token motion.enabled = 0) direkt.
import assert from "node:assert/strict";
import { copyFileSync, cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import { test } from "node:test";
import { build } from "esbuild";

const browser = process.env.OE_BROWSER ?? ["/usr/bin/chromium-headless-shell", "/usr/bin/chromium"].find((p) => existsSync(p));
const web = new URL("..", import.meta.url).pathname;
const shot = new URL("../../bin/shot.mjs", import.meta.url).pathname;
const MIME: Record<string, string> = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };

const CHECKS = String.raw`(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  await sleep(300);
  const q = (s) => document.querySelector(s) || (() => { throw new Error("missing " + s); })();
  const form = q(".access form");
  const fields = [...form.querySelectorAll("input, button")];
  if (fields.length < 3) throw new Error("form incomplete");
  for (const el of fields) {
    const r = el.getBoundingClientRect();
    if (r.height < 43.5) throw new Error(el.name + " too small: " + r.height);
    const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    if (top !== el) throw new Error((el.name || "button") + " is covered by " + (top && top.className));
  }
  const login = form.querySelector("input[name=login]");
  login.focus(); login.value = "anna";
  if (document.activeElement !== login || login.value !== "anna") throw new Error("form not usable");
  if (!q(".version-note").textContent.includes("Version")) throw new Error("version footer missing");
  if (!q(".game-title").textContent.includes("Orient Express")) throw new Error("title missing");
  const train = q(".title-stage .train");
  if (getComputedStyle(train).animationName !== "oe-train") throw new Error("animation not running: " + getComputedStyle(train).animationName);
  const stage = q(".title-stage");
  stage.setAttribute("data-still", "");
  if (getComputedStyle(train).animationName !== "none") throw new Error("data-still does not stop the animation");
  stage.removeAttribute("data-still");
  const rules = [...document.styleSheets].flatMap((s) => [...s.cssRules]).filter((r) => r.type === CSSRule.MEDIA_RULE && /prefers-reduced-motion: reduce/.test(r.conditionText));
  if (!rules.some((r) => [...r.cssRules].some((c) => c.selectorText && c.selectorText.includes(".title-stage") && c.style.animationName === "none"))) throw new Error("no reduced-motion rule for the stage");
})()`;

test("title screen: form usable above the scene, animation and static case", { skip: browser ? false : "no headless browser installed" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-title-test-"));
  try {
    await build({ entryPoints: [join(web, "main.ts")], bundle: true, format: "esm", target: "es2022", outfile: join(dir, "main.js"), logLevel: "silent", define: { __OE_VERSION__: JSON.stringify("0.1.0-dev") } });
    for (const f of ["index.html", "theme.css"]) copyFileSync(join(web, f), join(dir, f));
    copyFileSync(join(web, "ui", "kit", "kit.css"), join(dir, "kit.css"));
    copyFileSync(join(web, "ui", "frame", "frame.css"), join(dir, "frame.css"));
    cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
    copyFileSync(join(web, "fonts", "fonts.css"), join(dir, "fonts.css"));
    const { themesCss } = await import("../themes/css.ts");
    const { DEFAULT_THEME_ID, themes } = await import("../themes/index.ts");
    writeFileSync(join(dir, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
    const server = createServer((req, res) => {
      const p = new URL(req.url!, "http://x").pathname;
      if (p === "/healthz") { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify({ status: "ok", build: "abcdef123456", version: "0.1.0-dev", engine: "x" })); return; }
      if (p === "/me") { res.writeHead(401, { "Content-Type": "application/json" }); res.end(JSON.stringify({ error: "login_required", message: "x" })); return; }
      const f = join(dir, p === "/" ? "index.html" : p);
      if (existsSync(f)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); } else { res.writeHead(404); res.end(); }
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as { port: number }).port;
    const { spawn } = await import("node:child_process");
    for (const extra of [[], ["--device", "ipad", "--orientation", "portrait", "--engine", "chromium"]]) {
      const code = await new Promise<number>((resolve) => {
        const child = spawn(process.execPath, [shot, `http://127.0.0.1:${port}/#/login`, join(dir, "out.png"), "--width", "1280", "--height", "800", "--wait-for", ".version-note", "--eval", CHECKS, ...extra], { stdio: "pipe" });
        let err = "";
        child.stderr.on("data", (d) => { err += d; });
        child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
      });
      assert.equal(code, 0, `page checks failed (${extra.join(" ") || "desktop"}; see stderr)`);
    }
    server.closeAllConnections();
    server.close();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
