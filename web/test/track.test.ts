// Track picture (#146) on the real tile catalog excerpt of #144: geometry of bed, sleepers and rails,
// seamless joins at hex edges, taper of terminal track, zoom stages.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { samplesEvery } from "../render/axis-sample.ts";
import { Z1_FROM, Z2_FROM, zoomStage } from "../render/camera.ts";
import { TAPER_TIP, trackPicture, trackVisibility, widthFactor } from "../render/track.ts";
import { edgeMidpoint, hexFrame, tileGeometry, type TileParts, type Vec } from "../render/track-axes.ts";
import brett from "../themes/brett.json" with { type: "json" };
import atlas from "../themes/atlas.json" with { type: "json" };

const fx = JSON.parse(readFileSync(new URL("./fixtures/map-tiles.json", import.meta.url), "utf8")) as {
  layout: { edge_vectors: [number, number][] };
  tiles: Record<string, TileParts>;
};
const frame = hexFrame(fx.layout.edge_vectors);
const O: Vec = { x: 10, y: 5 };
const dims = brett.track;
const pairs = (a: number[]): Vec[] => Array.from({ length: a.length / 2 }, (_, i) => ({ x: a[2 * i]!, y: a[2 * i + 1]! }));
const dist = (p: Vec, q: Vec) => Math.hypot(p.x - q.x, p.y - q.y);

function straight() {
  // tile 8-like: a straight track edge 0 -> edge 3 (distance 3)
  const g = tileGeometry({ paths: [{ a: { edge: 0 }, b: { edge: 3 } }] }, 0, frame);
  return g.axes;
}

test("bed is dims.bedWidth wide, its ends sit on the edge midpoints and cut across the track", () => {
  const axes = straight();
  const pic = trackPicture(axes, O, dims);
  const bed = pairs(pic.beds[0]!);
  const m0 = edgeMidpoint(frame, 0), m3 = edgeMidpoint(frame, 3);
  const at = (m: Vec) => ({ x: m.x + O.x, y: m.y + O.y });
  // the polygon is left side then reversed right side: first and last point of the left side, then the right side's
  const half = bed.length / 2;
  const left0 = bed[0]!, right0 = bed[bed.length - 1]!, leftEnd = bed[half - 1]!, rightEnd = bed[half]!;
  assert.ok(Math.abs(dist(left0, right0) - dims.bedWidth) < 1e-9);
  assert.ok(Math.abs(dist(leftEnd, rightEnd) - dims.bedWidth) < 1e-9);
  const mid0 = { x: (left0.x + right0.x) / 2, y: (left0.y + right0.y) / 2 };
  const mid1 = { x: (leftEnd.x + rightEnd.x) / 2, y: (leftEnd.y + rightEnd.y) / 2 };
  assert.ok(dist(mid0, at(m0)) < 1e-9 && dist(mid1, at(m3)) < 1e-9);
  // the cut is perpendicular to the edge direction
  const dir = frame.unit[0]!;
  assert.ok(Math.abs((left0.x - right0.x) * dir.x + (left0.y - right0.y) * dir.y) < 1e-9);
});

test("rails run gauge apart, sleepers stand across the tangent and reach past both rails", () => {
  const axes = straight();
  const pic = trackPicture(axes, O, dims);
  assert.equal(pic.rails.length, 2);
  const [r1, r2] = pic.rails.map(pairs) as [Vec[], Vec[]];
  assert.equal(r1.length, r2.length);
  for (let i = 0; i < r1.length; i++) assert.ok(Math.abs(dist(r1[i]!, r2[i]!) - dims.gauge) < 1e-9);
  const ss = samplesEvery(axes[0]!, dims.sleeperSpacing, undefined, O);
  assert.equal(pic.sleepers.length, ss.length);
  pic.sleepers.forEach((q, i) => {
    const [a, b, c] = pairs(q) as [Vec, Vec, Vec];
    const s = ss[i]!;
    assert.ok(Math.abs(dist(a, b) - dims.sleeperLength) < 1e-9, "length across");
    assert.ok(Math.abs(dist(b, c) - dims.sleeperWidth) < 1e-9, "width along");
    assert.ok(Math.abs((b.x - a.x) * s.tx + (b.y - a.y) * s.ty) < 1e-9, "across the tangent");
    assert.ok(dims.sleeperLength / 2 > dims.gauge / 2 + dims.railWidth / 2);
  });
});

test("tracks of neighbouring hexes meet without a kink: same cut, same tangent, for every edge of every catalog tile", () => {
  for (const [name, parts] of Object.entries(fx.tiles)) {
    for (const r of [0, 1, 4]) {
      const g = tileGeometry(parts, r, frame);
      for (const axis of g.axes) {
        for (const [end, e, tan] of [[axis.a, axis.start, axis.startTangent], [axis.b, axis.end, axis.endTangent]] as const) {
          if (!("edge" in end)) continue;
          const u = frame.unit[end.edge]!;
          // tangent along the edge normal (into the hex: opposite u at the start, along u at the end)
          assert.ok(Math.abs(Math.abs(tan.x * u.x + tan.y * u.y) - 1) < 1e-6, `${name} r${r}: tangent normal to edge ${end.edge}`);
          assert.ok(Math.abs(Math.hypot(e.x, e.y) - frame.inradius) < 1e-6, `${name}: end on the edge midpoint`);
        }
      }
      const pic = trackPicture(g.axes, O, dims);
      assert.equal(pic.beds.length, g.axes.length, name);
      for (const b of pic.beds) assert.ok(b.every(Number.isFinite), name);
    }
  }
});

test("a terminal track tapers over its last 30 % towards the node; others keep full width", () => {
  const term = tileGeometry({ cities: [{ node: 0 }], paths: [{ a: { edge: 0 }, b: { node: 0 }, terminal: true }] }, 0, frame).axes[0]!;
  assert.equal(term.terminal, true);
  assert.equal(widthFactor(term, 0), 1);
  assert.equal(widthFactor(term, term.length * 0.7), 1);
  assert.ok(Math.abs(widthFactor(term, term.length) - TAPER_TIP) < 1e-9);
  assert.ok(widthFactor(term, term.length * 0.85) < 1 && widthFactor(term, term.length * 0.85) > TAPER_TIP);
  const plain = tileGeometry({ cities: [{ node: 0 }], paths: [{ a: { edge: 0 }, b: { node: 0 } }] }, 0, frame).axes[0]!;
  assert.equal(widthFactor(plain, plain.length), 1);
  // the tip of the bed is narrower than its root
  const bed = pairs(trackPicture([term], O, dims).beds[0]!);
  const half = bed.length / 2;
  assert.ok(Math.abs(dist(bed[0]!, bed[bed.length - 1]!) - dims.bedWidth) < 1e-9, "root");
  assert.ok(Math.abs(dist(bed[half - 1]!, bed[half]!) - dims.bedWidth * TAPER_TIP) < 1e-9, "tip");
});

test("crossing paths without a node: one bed, sleeper set and two rails per axis", () => {
  const g = tileGeometry({ paths: [{ a: { edge: 0 }, b: { edge: 3 } }, { a: { edge: 1 }, b: { edge: 4 } }] }, 0, frame);
  const pic = trackPicture(g.axes, O, dims);
  assert.equal(pic.beds.length, 2);
  assert.equal(pic.rails.length, 4);
  assert.equal(pic.lines.length, 2);
});

test("zoom stages: Z0 line, Z1 bed and rails, Z2 everything", () => {
  assert.deepEqual(trackVisibility(0), { line: true, bed: false, sleepers: false, rails: false });
  assert.deepEqual(trackVisibility(1), { line: false, bed: true, sleepers: false, rails: true });
  assert.deepEqual(trackVisibility(2), { line: false, bed: true, sleepers: true, rails: true });
  assert.equal(zoomStage(Z1_FROM - 1), 0);
  assert.equal(zoomStage(Z2_FROM + 1), 2);
});

test("both themes give the track picture its own colours and a consistent geometry", () => {
  for (const t of [brett, atlas]) {
    assert.ok(t.map.bed && t.map.sleeper && t.map.rail);
    assert.ok(t.track.sleeperLength >= t.track.gauge + t.track.railWidth);
    assert.ok(t.track.bedWidth >= t.track.sleeperLength);
  }
});
