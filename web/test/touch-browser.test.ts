// Touch operation of the map (#259) under the iPad profile via bin/shot: real touch input (oeTouch) for tap,
// selection by tap, one-finger pan with inertia, pinch zoom about the finger midpoint, double tap zoom,
// the selection list for ambiguous taps (hexes at overview, slots in a city) and its 44 px entries.
// Chromium engine only for multi-touch (WebKit offers tap only: those parts report "skipped" and the tap
// parts still run). Skipped without a headless browser.
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

// Runs inside the page.
const CHECKS = (w: number, h: number) => String.raw`(async () => {
  const fail = (m) => { throw new Error(m); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const m = window.oeMap || fail("no window.oeMap");
  const c = document.querySelector("canvas") || fail("no canvas");
  const box = c.getBoundingClientRect();
  const abs = (p) => ({ x: box.left + p.x, y: box.top + p.y });
  const tap = async (p) => { await window.oeTouch("start", [abs(p)]); await sleep(30); await window.oeTouch("end", []); await sleep(60); };
  const multi = async (f) => { try { await f(); return true; } catch (e) { if (/Chromium-engine only/.test(String(e))) return false; throw e; } };
  const events = [], hovers = [], cities = [];
  m.on("hex", (d) => events.push(d.hex)); m.on("hover", (d) => hovers.push(d.hex)); m.on("city", (d) => cities.push(d));
  const picker = () => document.querySelector(".map-picker");
  const inside = (p) => p.x > 60 && p.y > 60 && p.x < box.width - 60 && p.y < box.height - 60;

  // 1. Zoomed in until a hex is finger-sized: a tap selects it (hover outline = selection) and reports it, no list.
  m.flyTo("S42"); await sleep(1000); await m.rendered();
  // Zoom with the wheel until a hex is as wide as a finger target (portrait: the 4x zoom limit may stop short of it, then step 1 only checks the selection).
  for (let n = 0; n < 12 && m.view.zoom * 0.866 < 22; n++) { c.dispatchEvent(new WheelEvent("wheel", { deltaY: -400, clientX: box.left + box.width / 2, clientY: box.top + box.height / 2, bubbles: true, cancelable: true })); await m.rendered(); }
  const centre = { x: box.width / 2, y: box.height / 2 };
  const id = m.scene.grid.hexes.map((x) => x.id).find((i) => { const p = m.hexOnScreen(i); return p && inside(p) && Math.hypot(p.x - centre.x, p.y - centre.y) < 150; });
  const p1 = m.hexOnScreen(id);
  events.length = 0; hovers.length = 0;
  await tap(p1);
  const finger = m.view.zoom * 0.866 >= 22;
  if (finger && picker()) fail("a list at a finger-sized hex");
  if (!finger) { const pk = picker(); if (pk) { pk.querySelector("button").click(); } }
  if (finger && events[events.length - 1] !== id) fail("tap on " + id + " gave " + events);
  if (finger && hovers[hovers.length - 1] !== id) fail("tap did not select/show " + id + ": " + hovers);
  // The selection stays after the finger lifts (no pointerleave clearing).
  await sleep(100);
  if (finger && hovers[hovers.length - 1] !== id) fail("selection lost: " + hovers);

  // 2. Selection list at overview: hexes are far smaller than a finger.
  m.fit(); await m.rendered();
  // At the correct fit (#287) the overview of this map is nearly finger-sized (hex spacing about 26 px > reach 22): zoom out until neighbours lie within reach.
  for (let n = 0; n < 12 && m.view.zoom * 1.732 > 18; n++) { c.dispatchEvent(new WheelEvent("wheel", { deltaY: 200, clientX: box.left + box.width / 2, clientY: box.top + box.height / 2, bubbles: true, cancelable: true })); await m.rendered(); }
  // The hex nearest the canvas centre: at the correct fit (#287) a hex on the map's edge may have no neighbour within reach.
  const o = m.scene.grid.hexes.map((x) => x.id).filter((i) => { const p = m.hexOnScreen(i); return p && inside(p); })
    .sort((a, b) => { const pa = m.hexOnScreen(a), pb = m.hexOnScreen(b); return Math.hypot(pa.x - centre.x, pa.y - centre.y) - Math.hypot(pb.x - centre.x, pb.y - centre.y); })[0];
  events.length = 0;
  await tap(m.hexOnScreen(o));
  const list = picker() || fail("no selection list at overview (events " + events + ", hovers " + hovers.slice(-2) + ", zoom " + m.view.zoom + ", box " + box.width + "x" + box.height + ", hex " + o + " at " + JSON.stringify(m.hexOnScreen(o)) + ")");
  const entries = [...list.querySelectorAll("button")];
  if (entries.length < 2 || entries.length > 5) fail("list with " + entries.length + " entries");
  for (const b of entries) { const r = b.getBoundingClientRect(); if (r.height < 43.5 || r.width < 43.5) fail("entry " + r.width + "x" + r.height); }
  entries[entries.length - 1].click();
  if (picker()) fail("list stays open after a choice");
  if (events.length !== 1) fail("choice reported " + events);
  const chosen = events[0];
  if (hovers[hovers.length - 1] !== chosen) fail("choice not selected");

  // 3. Multi-touch parts (Chromium engine).
  const ranMulti = await multi(async () => {
    m.fit(); await m.rendered();
    // Pan with one finger: 120 px right/down, slowly (no inertia at rest), no hex event.
    events.length = 0;
    const a = { x: box.width * 0.35, y: box.height * 0.4 };
    const v0 = m.view;
    await window.oeTouch("start", [abs(a)]); await sleep(20);
    for (let i = 1; i <= 6; i++) { await window.oeTouch("move", [abs({ x: a.x + i * 20, y: a.y + i * 10 })]); await sleep(30); }
    await sleep(150);
    await window.oeTouch("end", []); await sleep(150); await m.rendered();
    if (events.length) fail("drag was a tap: " + events);
    const dx = m.view.panX - v0.panX, dy = m.view.panY - v0.panY;
    if (Math.abs(dx - 120) > 25 || Math.abs(dy - 60) > 15) fail("pan " + dx + "," + dy);
    if (picker()) fail("list after drag");
    // Fast flick: the view keeps moving after the finger lifted (inertia), then stops.
    // (zoomed in, so the map edge does not clamp the glide)
    c.dispatchEvent(new WheelEvent("wheel", { deltaY: -800, clientX: box.left + box.width / 2, clientY: box.top + box.height / 2, bubbles: true, cancelable: true })); await m.rendered();
    // The CDP round trip is slower than a real finger's 60 Hz, so the flick is sent as touch pointer events with real-time spacing.
    // Software-rendered frames take ~130 ms here, so the events are created first with 16 ms real-time spacing (that is what
    // timeStamp records) and dispatched afterwards in one go: the gesture the handlers see is a 60 Hz finger, deterministically.
    const mk = (type, x) => new PointerEvent(type, { clientX: box.left + x, clientY: box.top + 300, pointerId: 7, pointerType: "touch", isPrimary: true, bubbles: true });
    const flick = [mk("pointerdown", 300)];
    for (let i = 1; i <= 6; i++) { await sleep(16); flick.push(mk("pointermove", 300 + i * 30)); }
    await sleep(16); flick.push(mk("pointerup", 480));
    for (const ev of flick) c.dispatchEvent(ev);
    const atRelease = m.view.panX;
    await sleep(500); await m.rendered();
    if (!(m.view.panX > atRelease + 5)) fail("no inertia: " + atRelease + " -> " + m.view.panX);
    // Settles: slow software frames stretch the glide in real time, so wait until two reads 400 ms apart agree (at most 8 s).
    let prev = m.view.panX, settled = false;
    for (let i = 0; i < 20 && !settled; i++) { await sleep(400); settled = Math.abs(m.view.panX - prev) < 1; prev = m.view.panX; }
    if (!settled) fail("inertia did not settle");
    // Pinch: fingers 80 px apart spread to 240 px about their midpoint: the ground under the midpoint stays, zoom x3.
    m.fit(); await m.rendered();
    const mid = { x: box.width * 0.5, y: box.height * 0.45 };
    const z0 = m.view.zoom;
    const under0 = m.scene.grid.hexes.map((x) => x.id).find((i) => { const p = m.hexOnScreen(i); return p && Math.hypot(p.x - mid.x, p.y - mid.y) < 8; });
    const pa = { x: mid.x - 40, y: mid.y, id: 1 }, pb = { x: mid.x + 40, y: mid.y, id: 2 };
    await window.oeTouch("start", [abs(pa), abs(pb)]); await sleep(30);
    for (let i = 1; i <= 4; i++) { await window.oeTouch("move", [abs({ ...pa, x: pa.x - i * 20 }), abs({ ...pb, x: pb.x + i * 20 })]); await sleep(30); }
    await window.oeTouch("end", []); await sleep(100); await m.rendered();
    const k = m.view.zoom / z0;
    if (k < 2.5 || k > 3.5) fail("pinch factor " + k);
    if (under0) { const q = m.hexOnScreen(under0); if (Math.hypot(q.x - mid.x, q.y - mid.y) > 25) fail("pinch drifted from the midpoint: " + JSON.stringify(q)); }
    // Double tap zooms in about the finger.
    m.fit(); await m.rendered();
    const z1 = m.view.zoom, dt = { x: box.width * 0.45, y: box.height * 0.4 };
    const u = m.scene.grid.hexes.map((x) => x.id).find((i) => { const p = m.hexOnScreen(i); return p && Math.hypot(p.x - dt.x, p.y - dt.y) < 8; });
    // Created with real-time spacing, dispatched together (a slow software frame between two taps would otherwise exceed the double tap window).
    const dk = (type) => new PointerEvent(type, { clientX: box.left + dt.x, clientY: box.top + dt.y, pointerId: 9, pointerType: "touch", isPrimary: true, bubbles: true });
    const taps = [dk("pointerdown")]; await sleep(20); taps.push(dk("pointerup")); await sleep(80); taps.push(dk("pointerdown")); await sleep(20); taps.push(dk("pointerup"));
    for (const ev of taps) c.dispatchEvent(ev);
    await sleep(900); await m.rendered();
    if (!(m.view.zoom > z1 * 1.8)) fail("double tap zoom " + z1 + " -> " + m.view.zoom);
    if (u) { const q = m.hexOnScreen(u); if (Math.hypot(q.x - dt.x, q.y - dt.y) > 30) fail("double tap drifted"); }
    if (picker()) fail("list after double tap");
  });

  // 4. Slots: city with several tokens, finger between two slots gives a list; a tap on a slot gives that city.
  m.setState({ meta: { current: null }, corporations: [{ id: "PLM", closed: false, floated: true, tokens: [] }, { id: "KK", closed: false, floated: true, tokens: [] }],
    map: [{ hex: "Q30", tile: { name: "x", rotation: 0, color: "yellow" }, tokens: [{ city: 0, corporations: ["PLM"] }, { city: 1, corporations: ["KK"] }] }] });
  m.flyTo("Q30"); await sleep(1000); await m.rendered();
  for (let n = 0; n < 12 && m.view.zoom * 0.866 < 22; n++) { c.dispatchEvent(new WheelEvent("wheel", { deltaY: -400, clientX: box.left + box.width / 2, clientY: box.top + box.height / 2, bubbles: true, cancelable: true })); await m.rendered(); }
  m.flyTo("Q30"); await sleep(1000); await m.rendered();
  const toks = m.layer("objects").children.filter((k) => k.visible);
  if (toks.length !== 2) fail("tokens " + toks.length);
  cities.length = 0;
  await tap(toks[0].position);
  if (picker()) fail("list on a direct slot hit");
  if (cities.length !== 1 || cities[0].hex !== "Q30") fail("tap on a slot " + JSON.stringify(cities));
  return JSON.stringify({ ranMulti, zoom: m.view.zoom });
})()`;

for (const orientation of ["landscape", "portrait"] as const) {
  test(`touch on the map under the iPad profile, ${orientation}: tap selects, list for ambiguous taps, pan, inertia, pinch, double tap`, { skip: browser ? false : "no headless browser installed", timeout: 60000 }, async () => {
    const dir = mkdtempSync(join(tmpdir(), "oe-touch-test-"));
    try {
      await build({ entryPoints: [join(web, "main.ts")], bundle: true, format: "esm", target: "es2022", outfile: join(dir, "main.js"), logLevel: "silent" });
      copyFileSync(join(web, "index.html"), join(dir, "index.html"));
      copyFileSync(join(web, "theme.css"), join(dir, "theme.css"));
      writeFileSync(join(dir, "map.json"), fixtureMap());
      const [pw, ph] = [834, 1194];
      const [w, h] = orientation === "landscape" ? [ph, pw] : [pw, ph];
      const out = join(dir, "out.png");
      const r = spawnSync(process.execPath, [shot, `${join(dir, "index.html")}#/map?src=/map.json&pitch=0&yaw=0`, out,
        "--device", "ipad", "--orientation", orientation, "--wait-for", ".map-dev[data-ready]", "--eval", CHECKS(w, h), "--delay", "0"], { encoding: "utf8", timeout: 55000 });
      assert.equal(r.status, 0, r.stderr + r.stdout);
      assert.doesNotMatch(r.stderr, /page error/);
      console.log(r.stdout.trim().split("\n").pop());
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
}
