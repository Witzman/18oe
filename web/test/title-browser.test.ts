// Titel- und Anmeldebildschirm im Browser (#280): Formular sofort bedienbar (Felder >= 44 px, nicht von der
// Szene verdeckt), Versionsfuß bleibt, Slider (#460: sechs Bilder, Punkte >= 44 px, Punkt wählt Bild), statischer Fall (data-still / prefers-reduced-motion).
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
  // #462: the form is hidden until the "Login" button (top right) opens the dialog
  const dialog = q(".login-dialog");
  if (dialog.open) throw new Error("dialog open at the start");
  if (q(".access form").getBoundingClientRect().height !== 0) throw new Error("form visible without the dialog");
  const opener = q(".login-open");
  const ob = opener.getBoundingClientRect();
  if (ob.height < 43.5 || ob.width < 43.5) throw new Error("login button too small");
  if (ob.right < innerWidth * 0.8 || ob.top > innerHeight * 0.2) throw new Error("login button not top right: " + JSON.stringify(ob) + " in " + innerWidth + "x" + innerHeight);
  opener.click();
  if (!dialog.open) throw new Error("login button does not open the dialog");
  dialog.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
  dialog.close(); // headless: Escape is not delivered as a cancel; closing must work and the button reopen it
  opener.click();
  if (!dialog.open) throw new Error("dialog does not reopen");
  q(".login-close").click();
  if (dialog.open) throw new Error("close button does not close");
  opener.click();
  dialog.dispatchEvent(new MouseEvent("click", { bubbles: true })); // click on the backdrop = target is the dialog
  if (dialog.open) throw new Error("click beside the form does not close");
  opener.click();
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
  dialog.close(); // the modal would cover the dots below
  if (!q(".version-note").textContent.includes("Version")) throw new Error("version footer missing");
  if (!q(".game-title").textContent.includes("Orient Express")) throw new Error("title missing");
  const slides = [...document.querySelectorAll(".title-stage .title-slide")];
  if (slides.length !== 6) throw new Error("slides: " + slides.length);
  if (slides.filter((s) => s.hasAttribute("data-active")).length !== 1) throw new Error("not exactly one active slide");
  const dots = [...document.querySelectorAll(".title-stage .title-dot")];
  if (dots.length !== 6) throw new Error("dots: " + dots.length);
  for (const d of dots) { const r = d.getBoundingClientRect(); if (r.width < 43.5 || r.height < 43.5) throw new Error("dot too small: " + r.width + "x" + r.height); }
  const last = dots[dots.length - 1];
  const at = last.getBoundingClientRect();
  if (document.elementFromPoint(at.left + at.width / 2, at.top + at.height / 2) !== last && !last.contains(document.elementFromPoint(at.left + at.width / 2, at.top + at.height / 2))) throw new Error("dot is covered");
  last.click();
  if (!slides[slides.length - 1].hasAttribute("data-active") || slides.filter((s) => s.hasAttribute("data-active")).length !== 1) throw new Error("dot does not choose its slide");
  const stage = q(".title-stage");
  stage.setAttribute("data-still", "");
  if (parseFloat(getComputedStyle(slides[0]).transitionDuration) !== 0) throw new Error("data-still keeps the fade");
  stage.removeAttribute("data-still");
  const rules = [...document.styleSheets].flatMap((s) => [...s.cssRules]).filter((r) => r.type === CSSRule.MEDIA_RULE && /prefers-reduced-motion: reduce/.test(r.conditionText));
  if (!rules.some((r) => [...r.cssRules].some((c) => c.selectorText && c.selectorText.includes(".title-slide") && c.style.transition === "none"))) throw new Error("no reduced-motion rule for the slides");
})()`;

test("title screen: form usable above the slider, dots and static case", { skip: browser ? false : "no headless browser installed" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-title-test-"));
  try {
    await build({ entryPoints: [join(web, "main.ts")], bundle: true, format: "esm", target: "es2022", outfile: join(dir, "main.js"), logLevel: "silent", define: { __OE_VERSION__: JSON.stringify("0.1.0-dev") } });
    for (const f of ["index.html", "theme.css"]) copyFileSync(join(web, f), join(dir, f));
    copyFileSync(join(web, "ui", "kit", "kit.css"), join(dir, "kit.css"));
    copyFileSync(join(web, "ui", "frame", "frame.css"), join(dir, "frame.css"));
    cpSync(join(web, "fonts"), join(dir, "fonts"), { recursive: true });
    cpSync(join(web, "title"), join(dir, "title"), { recursive: true });
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
