// Feedback of registering and logging in in the browser (#286): busy state, success, one message per failure.
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
  const waitText = async (sel, re, what) => {
    for (let i = 0; i < 60; i++) { const el = document.querySelector(sel); if (el && re.test(el.textContent)) return; await sleep(50); }
    throw new Error(what + ": expected " + re + " in " + sel + " but got " + JSON.stringify((document.querySelector(sel) || {}).textContent));
  };
  const fill = (name, v) => { const el = q(".access form input[name=" + name + "]"); el.value = v; };
  const submit = () => q(".access form button[type=submit]").click();
  await sleep(300);
  // wrong login: own error text, button usable again
  fill("login", "anna"); fill("password", "falsch-falsch"); submit();
  await waitText(".access .status", /Anmeldung läuft/, "busy login");
  await waitText(".access .error", /stimmt nicht/, "wrong login");
  if (q(".access .status").textContent) throw new Error("status not cleared on error");
  if (q("button[type=submit]").disabled) throw new Error("button stays disabled after an error");
  // rate limit, server error, unparsable answer
  fill("login", "limit"); submit(); await waitText(".access .error", /Zu viele Versuche/, "rate limit");
  fill("login", "boom"); submit(); await waitText(".access .error", /boom/, "server error");
  fill("login", "garbled"); submit(); await waitText(".access .error", /unerwartet/, "unparsable 200");
  fill("login", "html502"); submit(); await waitText(".access .error", /502/, "html 502");
  // successful login: success message first, then the lobby
  fill("login", "anna"); fill("password", "richtig-richtig"); submit();
  await waitText(".access .status", /Angemeldet als "Anna Lee"/, "login ok");
  await waitText("body", /Partien|Neue Partie|Anna Lee/, "lobby after login");
  // second account in the same browser: registration page, errors, success
  location.hash = "#/register";
})()`;

const CHECKS2 = String.raw`(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s) => document.querySelector(s) || (() => { throw new Error("missing " + s); })();
  const waitText = async (sel, re, what) => {
    for (let i = 0; i < 60; i++) { const el = document.querySelector(sel); if (el && re.test(el.textContent)) return; await sleep(50); }
    throw new Error(what + ": expected " + re + " in " + sel + " but got " + JSON.stringify((document.querySelector(sel) || {}).textContent));
  };
  const fill = (name, v) => { q(".access form input[name=" + name + "]").value = v; };
  const submit = () => q(".access form button[type=submit]").click();
  await sleep(300);
  q(".access form input[name=code]");
  fill("name", "Bob"); fill("email", "bob@example.de"); fill("password", "geheim-geheim"); fill("code", "falsch"); submit();
  await waitText(".access .status", /Konto wird angelegt/, "busy register");
  await waitText(".access .error", /Einladungscode ist falsch/, "invalid invite");
  fill("name", "Taken"); fill("code", "richtig"); submit(); await waitText(".access .error", /schon vergeben/, "name taken");
  fill("name", "Bob"); fill("email", "dup@example.de"); submit(); await waitText(".access .error", /keine Registrierung möglich/, "email taken");
  fill("email", "bob@example.de"); submit();
  await waitText(".access .status", /Konto "Bob" angelegt\. Du bist angemeldet/, "register ok");
})()`;

function stub(dir: string) {
  let me: { id: string; name: string } | null = null;
  const send = (res: import("node:http").ServerResponse, status: number, body: unknown, type = "application/json") => {
    res.writeHead(status, { "Content-Type": type });
    res.end(typeof body === "string" ? body : JSON.stringify(body));
  };
  return createServer((req, res) => {
    const p = new URL(req.url!, "http://x").pathname;
    let raw = "";
    req.on("data", (d) => { raw += d; });
    req.on("end", () => {
      const data = raw ? JSON.parse(raw) : {};
      if (p === "/healthz") return send(res, 200, { status: "ok", build: "abcdef123456", version: "0.1.0-dev", engine: "x" });
      if (p === "/me") return me ? send(res, 200, me) : send(res, 401, { error: "login_required", message: "x" });
      if (p === "/games") return send(res, 200, { games: [] });
      if (p === "/logout") { me = null; return send(res, 200, { ok: true }); }
      if (p === "/login") {
        setTimeout(() => {
          const l = data.login;
          if (l === "limit") return send(res, 429, { error: "rate_limited", message: "x" });
          if (l === "boom") return send(res, 500, { error: "internal_error", message: "boom" });
          if (l === "garbled") return send(res, 200, "<html>not json</html>", "text/html");
          if (l === "html502") return send(res, 502, "<html>bad gateway</html>", "text/html");
          if (l === "anna" && data.password === "richtig-richtig") { me = { id: "u1", name: "Anna Lee" }; return send(res, 200, me); }
          send(res, 401, { error: "invalid_login", message: "x" });
        }, 150);
        return;
      }
      if (p === "/register") {
        setTimeout(() => {
          if (data.code !== "richtig") return send(res, 403, { error: "invalid_invite", message: "x" });
          if (data.name === "Taken") return send(res, 409, { error: "name_taken", message: "x" });
          if (data.email === "dup@example.de") return send(res, 409, { error: "registration_failed", message: "x" });
          me = { id: "u2", name: data.name }; send(res, 201, me);
        }, 150);
        return;
      }
      const f = join(dir, p === "/" ? "index.html" : p);
      if (existsSync(f)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); } else { res.writeHead(404); res.end(); }
    });
  });
}

test("login and registration report every step and every failure (#286)", { skip: browser ? false : "no headless browser installed" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-access-test-"));
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
    const server = stub(dir);
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as { port: number }).port;
    const { spawn } = await import("node:child_process");
    // Login flow ends in the lobby; then the same browser session cannot register (already logged in), so the
    // registration flow runs in its own page load against a fresh stub state.
    const run = (url: string, js: string) => new Promise<number>((resolve) => {
      const child = spawn(process.execPath, [shot, url, join(dir, "out.png"), "--width", "1280", "--height", "800", "--wait-for", ".version-note", "--eval", js], { stdio: "pipe" });
      let err = "";
      child.stderr.on("data", (d) => { err += d; });
      child.on("close", (c) => { if (c) console.error(err); resolve(c ?? 1); });
    });
    try {
      assert.equal(await run(`http://127.0.0.1:${port}/#/login`, CHECKS.replace('location.hash = "#/register";', "")), 0, "login feedback checks failed");
      assert.equal(await run(`http://127.0.0.1:${port}/#/register`, CHECKS2), 0, "register feedback checks failed");
    } finally {
      server.closeAllConnections();
      server.close();
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
