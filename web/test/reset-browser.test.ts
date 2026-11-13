// Passwort zurücksetzen im Browser (#282, POC): Link auf der Anmeldeseite, E-Mail eingeben, das neue Passwort
// erscheint auf der Seite, Bedienelemente >= 44 px. Der Server ist ein Stub. Ohne Browser übersprungen.
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
  const q = (s) => document.querySelector(s) || (() => { throw new Error("missing " + s); })();
  await sleep(300);
  const link = q('a[href="#/reset"]');
  if (link.getBoundingClientRect().height < 43.5) throw new Error("reset link too small");
  link.click();
  await sleep(300);
  const form = q(".access form");
  for (const el of form.querySelectorAll("input, button")) {
    const r = el.getBoundingClientRect();
    if (r.height < 43.5) throw new Error((el.name || "button") + " too small: " + r.height);
  }
  const email = form.querySelector("input[name=email]");
  email.value = "nope";
  form.querySelector("button[type=submit]").click();
  await sleep(200);
  if (!q(".error").textContent) throw new Error("bad e-mail not reported");
  email.value = "anna@example.de";
  form.querySelector("button[type=submit]").click();
  await sleep(500);
  if (q("[data-testid=new-password]").textContent !== "Abc123Xyz789Qw") throw new Error("password not shown: " + q(".reset-result").textContent);
  if (q(".reset-result").hidden) throw new Error("result hidden");
})()`;

test("reset password page: link, validation, new password shown", { skip: browser ? false : "no headless browser installed" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-reset-test-"));
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
      if (p === "/reset-password" && req.method === "POST") { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify({ password: "Abc123Xyz789Qw" })); return; }
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
