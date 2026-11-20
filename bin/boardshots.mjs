// Screenshots of the real built UI for the feedback board (workshop #374): every scene of bin/boardshots.json is
// one recorded game fixture served by a stub API (no engine), opened by bin/shot.mjs at 1747x923.
//   node bin/boardshots.mjs <webDir> <outDir> <catalog.json> [scene-name ...]     all scenes, or the named ones
// Each scene is its own bin/shot.mjs run under a hard timeout (heavy.lock is taken by bin/shot.mjs); stop at the
// first failure is not wanted, so the exit code is the number of failed scenes (0 = all taken).
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, extname, join, resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const MIME = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".json": "application/json", ".woff2": "font/woff2", ".map": "application/json" };

export function loadScenes(file = join(here, "boardshots.json")) {
  return JSON.parse(readFileSync(file, "utf8"));
}

export function pickScenes(scenes, names) {
  if (!names.length) return scenes;
  const unknown = names.filter((n) => !scenes.some((s) => s.name === n));
  if (unknown.length) throw new Error(`unknown scene: ${unknown.join(", ")}`);
  return scenes.filter((s) => names.includes(s.name));
}

// One scene: serve dist + fixtures, run bin/shot.mjs, stop the server.
async function one(web, out, fixture, catalog, evalJs, scale = 1) {
  const dist = join(web, "dist");
  const read = (f) => JSON.parse(readFileSync(join(web, "test", "fixtures", f), "utf8"));
  const game = read(`games/${fixture}.json`);
  const geometry = read("map-geometry.json");
  const zones = new Map(read("map-zones.json").hexes.map((h) => [h.id, h]));
  const tracks = read("map-tiles.json");
  const printed = new Map(tracks.hexes.map((h) => [h.id, h]));
  const parts = ({ paths, cities, towns, double_towns, offboards, junction, name, color } = {}) => ({ paths, cities, towns, double_towns, offboards, junction, name, color });
  geometry.hexes = geometry.hexes.map((h) => ({ ...h, ...zones.get(h.id), ...parts(printed.get(h.id)) }));
  geometry.tiles = tracks.tiles;
  const MAP = JSON.stringify(geometry);
  const CATALOG = readFileSync(catalog);
  const server = createServer((req, res) => {
    const p = new URL(req.url, "http://x").pathname;
    const json = (o) => { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify(o)); };
    if (p === "/me") return json({ id: game.viewer ?? "p0", name: game.viewer ?? "p0" });
    if (p === "/games/1") return json(game);
    if (p === "/games/1/version") return json({ seq: game.seq, status: "active" });
    if (p === "/games/1/actions") return json(game);
    if (p === "/games/1/log") return json({ lines: game.state.log ?? [], from: 0 });
    if (p === "/map") { res.writeHead(200, { "Content-Type": "application/json" }); res.end(MAP); return; }
    if (p === "/catalog") { res.writeHead(200, { "Content-Type": "application/json" }); res.end(CATALOG); return; }
    const f = join(dist, p === "/" ? "index.html" : p);
    if (existsSync(f) && f.startsWith(dist)) { res.writeHead(200, { "Content-Type": MIME[extname(f)] ?? "application/octet-stream" }); res.end(readFileSync(f)); }
    else { res.writeHead(404); res.end(); }
  });
  await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
  const port = server.address().port;
  const args = [join(here, "shot.mjs"), `http://127.0.0.1:${port}/#/game/1`, out, "--width", "1747", "--height", "923", "--wait-for", ".frame-tabs", "--delay", "2500"];
  if (evalJs) args.push("--eval", evalJs);
  if (scale !== 1) args.push("--scale", String(scale));
  const child = spawn(process.execPath, args, { stdio: "inherit" });
  const code = await new Promise((r) => child.on("close", (c) => r(c ?? 1)));
  server.closeAllConnections?.();
  server.close();
  return code;
}

async function main(argv) {
  if (argv[0] === "--one") {
    const [, web, out, fixture, catalog, evalJs, scale] = argv;
    process.exit(await one(web, out, fixture, catalog, evalJs || undefined, Number(scale) || 1));
  }
  const [web, outDir, catalog, ...names] = argv;
  if (!web || !outDir || !catalog) {
    console.error("usage: node bin/boardshots.mjs <webDir> <outDir> <catalog.json> [scene-name ...]");
    process.exit(2);
  }
  mkdirSync(outDir, { recursive: true });
  let failed = 0;
  for (const scene of pickScenes(loadScenes(), names)) {
    const out = resolve(outDir, `${scene.name}.png`);
    const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url), "--one", resolve(web), out, scene.fixture, resolve(catalog), scene.eval ?? "", String(scene.scale ?? 1)],
      { stdio: "inherit", timeout: 120_000, killSignal: "SIGKILL" });
    const ok = r.status === 0 && existsSync(out);
    if (!ok) failed += 1;
    console.log(`${ok ? "ok    " : "FAILED"} ${scene.name}  ${scene.title}`);
  }
  process.exit(failed);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main(process.argv.slice(2));
