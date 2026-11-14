// The map under the iPad profile (#260): the same scene as map-browser.test.ts via bin/shot --device ipad,
// both orientations. Runs on real WebKit when .tools/pw can start it, otherwise on the Chromium approximation
// (iPad viewport, DPR 2, touch emulation, iPad UA; no Safari behaviour). The engine is printed, not asserted.
// Checks: map appears, WebGL runs, viewport size/DPR/touch of the profile, a real touch tap selects a hex,
// a two-finger gesture arrives as two touch pointers (pinch zoom itself belongs to #259, only reported).
// Skipped without a headless browser.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { build } from "esbuild";

const browser = process.env.OE_BROWSER ?? ["/usr/bin/chromium-headless-shell", "/usr/bin/chromium"].find((p) => existsSync(p));
const web = new URL("..", import.meta.url).pathname;
const shot = new URL("../../bin/shot.mjs", import.meta.url).pathname;

function fixtureMap(): string {
  const read = (f: string) => JSON.parse(readFileSync(join(web, "test", "fixtures", f), "utf8"));
  const geometry = read("map-geometry.json");
  const zones = new Map((read("map-zones.json").hexes as { id: string }[]).map((h) => [h.id, h]));
  // Track parts (#146): printed track per hex and the tile catalog, from the #144 excerpt of GET /map.
  const tracks = read("map-tiles.json");
  const printed = new Map((tracks.hexes as { id: string }[]).map((h) => [h.id, h]));
  const parts = ({ paths, cities, towns, double_towns, offboards, junction }: Record<string, unknown>) => ({ paths, cities, towns, double_towns, offboards, junction });
  geometry.hexes = geometry.hexes.map((h: { id: string }) => ({ ...h, ...zones.get(h.id), ...parts(printed.get(h.id) ?? {}) }));
  geometry.tiles = tracks.tiles;
  return JSON.stringify(geometry);
}

// Runs inside the page. EXPECT is replaced by the profile numbers.
const CHECKS = (w: number, h: number) => String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const m = window.oeMap || fail("no window.oeMap");
  const c = document.querySelector("canvas") || fail("no canvas");
  if (!/iPad/.test(navigator.userAgent)) fail("user agent " + navigator.userAgent);
  if (!(navigator.maxTouchPoints > 0)) fail("no touch points");
  if (window.innerWidth !== ${w} || window.innerHeight !== ${h}) fail("viewport " + innerWidth + "x" + innerHeight);
  if (window.devicePixelRatio !== 2) fail("dpr " + devicePixelRatio);
  const gl = document.createElement("canvas").getContext("webgl2") || document.createElement("canvas").getContext("webgl");
  if (!gl) fail("no WebGL");
  if (document.documentElement.scrollHeight > innerHeight + 1 && getComputedStyle(document.body).overflow !== "hidden") console.warn("note: page scrolls (" + document.documentElement.scrollHeight + " > " + innerHeight + ")");
  if (!(m.stats().visibleBlocks > 0)) fail("no visible blocks");

  const box = c.getBoundingClientRect();
  let clicked = null, types = [];
  m.on("hex", (d) => { clicked = d.hex; });
  c.addEventListener("pointerdown", (e) => types.push(e.pointerType + ":" + e.pointerId));
  const id = m.scene.grid.hexes.map((h) => h.id).find((i) => { const p = m.hexOnScreen(i); return p.x > 40 && p.y > 40 && p.x < box.width - 40 && p.y < box.height - 40; });
  const p = m.hexOnScreen(id);
  const pt = { x: box.left + p.x, y: box.top + p.y };
  await window.oeTouch("start", [pt]); await sleep(30); await window.oeTouch("end", [pt]); await sleep(100);
  // At this zoom a hex is smaller than a finger: the tap opens the selection list (#259), whose first entry is the nearest hex.
  const list = document.querySelector(".map-picker");
  if (list) list.querySelector("button").click();
  if (clicked !== id) fail("touch tap on " + id + " gave " + clicked + " (events " + types + ")");
  if (!types.some((t) => t.startsWith("touch:"))) fail("tap was not a touch pointer: " + types);

  try {
    const a = { x: pt.x - 40, y: pt.y, id: 1 }, b = { x: pt.x + 40, y: pt.y, id: 2 };
    types = [];
    const z0 = JSON.stringify(m.stats());
    await window.oeTouch("start", [a, b]); await sleep(30);
    await window.oeTouch("move", [{ ...a, x: a.x - 60 }, { ...b, x: b.x + 60 }]); await sleep(30);
    await window.oeTouch("end", []); await sleep(100);
    if (new Set(types).size < 2) fail("two-finger gesture gave pointers " + types);
    console.warn("note: pinch delivered as " + types.join(",") + (z0 === JSON.stringify(m.stats()) ? "; stats unchanged (pinch zoom is #259)" : ""));
  } catch (e) { if (!/Chromium-engine only/.test(String(e))) throw e; }
})()`;

for (const orientation of ["landscape", "portrait"] as const) {
  for (const device of ["ipad", "ipad-10.2"]) {
    test(`map under the ${device} profile, ${orientation}: appears, WebGL, viewport, touch tap`, { skip: browser ? false : "no headless browser installed", timeout: 180000 }, async () => {
      const dir = mkdtempSync(join(tmpdir(), "oe-ipad-test-"));
      try {
        await build({ entryPoints: [join(web, "main.ts")], bundle: true, format: "esm", target: "es2022", outfile: join(dir, "main.js"), logLevel: "silent" });
        copyFileSync(join(web, "index.html"), join(dir, "index.html"));
        copyFileSync(join(web, "theme.css"), join(dir, "theme.css"));
        writeFileSync(join(dir, "map.json"), fixtureMap());
        const [pw, ph] = device === "ipad" ? [834, 1194] : [810, 1080];
        const [w, h] = orientation === "landscape" ? [ph, pw] : [pw, ph];
        const out = join(dir, "out.png");
        const r = spawnSync(process.execPath, [shot, `${join(dir, "index.html")}#/map?src=/map.json&pitch=0&yaw=0`, out,
          "--device", device, "--orientation", orientation, "--wait-for", ".map-dev[data-ready]", "--eval", CHECKS(w, h), "--delay", "0"], { encoding: "utf8", timeout: 170000 });
        assert.equal(r.status, 0, r.stderr + r.stdout);
        assert.doesNotMatch(r.stderr, /page error/);
        assert.ok(existsSync(out));
        console.log(r.stdout.trim().split("\n").pop());
      } finally { rmSync(dir, { recursive: true, force: true }); }
    });
  }
}
