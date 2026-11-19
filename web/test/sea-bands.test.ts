// Base surfaces (#477): the sea gradient by distance to the coast and the foam fringe, as pure numbers.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { coastRuns, foamLayers, seaBands, simplify, SEA_BAND_COUNT } from "../render/sea-bands.ts";
import type { MapGeometry } from "../render/mapdata.ts";
import { landRings } from "../render/coast.ts";
import { buildScene } from "../render/scene.ts";
import { renderTheme } from "../render/theme.ts";
import { themeById, themes } from "../themes/index.ts";

const here = dirname(fileURLToPath(import.meta.url));

test("seaBands: widest first, the outer ring reaches `reach` into the sea, the tint rises linearly towards the coast", () => {
  const bands = seaBands(6, 0.6);
  assert.equal(bands.length, SEA_BAND_COUNT);
  for (let i = 1; i < bands.length; i++) { assert.ok(bands[i]!.width < bands[i - 1]!.width); assert.ok(bands[i]!.alpha > bands[i - 1]!.alpha); }
  // a stroke is centred on the line: its outer half is the distance it reaches into the sea
  assert.ok(Math.abs(bands[0]!.width / 2 - 6) < 1e-9);
  const step = bands[1]!.alpha - bands[0]!.alpha;
  bands.forEach((b, i) => assert.ok(Math.abs(b.alpha - (bands[0]!.alpha + step * i)) < 1e-9));
  assert.ok(bands.at(-1)!.alpha <= 0.6 && bands.at(-1)!.alpha > 0.5);
});

test("seaBands: no reach or no tint means no bands", () => {
  assert.deepEqual(seaBands(0, 0.5), []);
  assert.deepEqual(seaBands(5, 0), []);
});

test("foamLayers: outer to inner, narrowing, the inner one most opaque; none at width 0", () => {
  const f = foamLayers(0.2, 0.8);
  assert.equal(f.length, 3);
  for (let i = 1; i < f.length; i++) { assert.ok(f[i]!.width < f[i - 1]!.width); assert.ok(f[i]!.alpha > f[i - 1]!.alpha); }
  assert.ok(f[0]!.alpha <= 0.8 && f.at(-1)!.alpha <= 0.8);
  assert.deepEqual(foamLayers(0, 0.8), []);
  assert.deepEqual(foamLayers(0.2, 0), []);
});

for (const theme of themes) {
  test(`${theme.id}: the base surface tokens are set within their ranges`, () => {
    const t = renderTheme({ theme, tileStyle: "full" });
    assert.ok(t.seaReach > 0 && t.seaCoastAlpha > 0, "sea gradient on");
    assert.ok(t.coastFoamWidth > 0 && t.coastFoamAlpha > 0, "foam on");
    assert.notEqual(t.map.land, 0xffffff, "land is no longer white");
    assert.notEqual(t.map.seaCoast, t.map.seaNorth);
  });
}

test("build time of the sea bands and the coast on the real map (budget #159, once per map)", () => {
  const geometry = JSON.parse(readFileSync(join(here, "fixtures", "map-geometry.json"), "utf8")) as MapGeometry;
  const theme = renderTheme({ theme: themeById("brett"), tileStyle: "full" });
  const scene = buildScene(geometry, theme);
  const t0 = performance.now();
  const rings = landRings(scene, { round: theme.coastRound, noise: theme.coastNoise });
  const bands = seaBands(theme.seaReach, theme.seaCoastAlpha);
  const ms = performance.now() - t0;
  const pts = rings.reduce((s, r) => s + r.points.length, 0);
  console.log(`# coast rings ${rings.length}, ${pts} points, ${bands.length} bands, ${ms.toFixed(1)} ms`);
  assert.ok(ms < 1000);
});

test("coastRuns: no stroke runs along the map border, every coast side is covered", () => {
  const geometry = JSON.parse(readFileSync(join(here, "fixtures", "map-geometry.json"), "utf8")) as MapGeometry;
  const theme = renderTheme({ theme: themeById("brett"), tileStyle: "full" });
  const scene = buildScene(geometry, theme);
  const rings = landRings(scene, { round: theme.coastRound, noise: theme.coastNoise });
  let withBorder = 0;
  for (const r of rings) {
    const runs = coastRuns(r);
    if (r.border.some(Boolean)) withBorder++;
    else assert.deepEqual(runs.map((x) => x.closed), [true]);
    for (const run of runs) assert.ok(run.points.length >= 2);
    if (r.border.some(Boolean) && !r.border.every(Boolean)) {
      // the runs reach every raw corner of a coast side: none of the raw border sides is a segment of a run
      const rawBorder = r.raw.flatMap((p, i) => (r.border[i] ? [[p, r.raw[(i + 1) % r.raw.length]!] as const] : []));
      for (const run of runs) for (let i = 0; i + 1 < run.points.length; i++) {
        const a = run.points[i]!, b = run.points[i + 1]!;
        for (const [p, q] of rawBorder) assert.ok(!(Math.hypot(a.x - p.x, a.y - p.y) < 1e-6 && Math.hypot(b.x - q.x, b.y - q.y) < 1e-6), "border side in a run");
      }
    }
  }
  assert.ok(withBorder > 0, "the real map has land on its border");
});

test("simplify: keeps the ends, stays within the tolerance of the original, drops points on a straight line", () => {
  const line = Array.from({ length: 20 }, (_, i) => ({ x: i, y: 0 }));
  assert.deepEqual(simplify(line, 0.01), [line[0], line[19]]);
  const wave = Array.from({ length: 200 }, (_, i) => ({ x: i * 0.1, y: Math.sin(i * 0.1) }));
  const s = simplify(wave, 0.05);
  assert.deepEqual([s[0], s.at(-1)], [wave[0], wave.at(-1)]);
  assert.ok(s.length < wave.length / 3, `${s.length} of ${wave.length}`);
  let worst = 0;
  for (const p of wave) { let best = Infinity; for (let i = 0; i + 1 < s.length; i++) best = Math.min(best, distToSeg(p, s[i]!, s[i + 1]!)); worst = Math.max(worst, best); }
  assert.ok(worst <= 0.05 + 1e-9, `worst ${worst}`);
  assert.deepEqual(simplify(wave, 0), wave);
});

function distToSeg(p: { x: number; y: number }, a: { x: number; y: number }, b: { x: number; y: number }): number {
  const dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy;
  const t = l2 === 0 ? 0 : Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2));
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}
