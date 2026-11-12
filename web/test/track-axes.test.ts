// Track axes (#144) against a real excerpt of GET /map: fixtures/map-tiles.json was
// generated from Oe::MapData.build (layout, the whole tile catalog with its track
// parts, every hex with printed track or nodes, and the block rows H..M x cols 18..34).
// To regenerate: in the repo, `bundler exec ruby -Ilib -e` over Oe::MapData.build,
// keeping layout, tiles[*]{color,count,cities,towns,double_towns,junction,offboards,paths}
// and hexes[*]{id,row,col,x,y,kind,color,name,neighbors + the same parts}.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { pointAt, polyline, samplesEvery } from "../render/axis-sample.ts";
import {
  add,
  cross,
  dot,
  edgeMidpoint,
  hexFrame,
  norm,
  sub,
  tileGeometry,
  type Axis,
  type PathEnd,
  type TileGeometry,
  type TileParts,
  type Vec,
} from "../render/track-axes.ts";

interface FixtureHex extends TileParts {
  id: string;
  row: number;
  col: number;
  x: number;
  y: number;
  kind: string;
  color: string;
  name?: string;
  neighbors: (string | null)[];
}
interface Fixture {
  layout: { edge_vectors: [number, number][] };
  tiles: Record<string, TileParts & { color: string; count: number }>;
  hexes: FixtureHex[];
  block: string[];
}

const fx = JSON.parse(readFileSync(new URL("./fixtures/map-tiles.json", import.meta.url), "utf8")) as Fixture;
const frame = hexFrame(fx.layout.edge_vectors);
const byId = new Map(fx.hexes.map((h) => [h.id, h]));
const TOL = 1e-6;
const SQRT3 = Math.sqrt(3);

const near = (p: Vec, q: Vec, tol = TOL): boolean => norm(sub(p, q)) < tol;
const hasTrack = (p: TileParts): boolean =>
  !!(p.paths || p.cities || p.towns || p.double_towns || p.offboards || p.junction !== undefined);
const isEdge = (e: PathEnd): e is { edge: number } => "edge" in e;

/** Everything a correct geometry must satisfy, for one tile at one rotation. */
function checkGeometry(label: string, parts: TileParts, r: number, g: TileGeometry): void {
  const paths = parts.paths ?? [];
  // one axis per engine path, in order, with the engine's ends (edges rotated)
  assert.equal(g.axes.length, paths.length, `${label}: one axis per path`);
  g.axes.forEach((ax, i) => {
    const p = paths[i]!;
    assert.equal(ax.path, i, label);
    for (const [end, orig] of [[ax.a, p.a], [ax.b, p.b]] as const) {
      if (isEdge(orig)) assert.deepEqual(end, { edge: (orig.edge + r) % 6 }, `${label} path ${i}`);
      else assert.deepEqual(end, { node: orig.node }, `${label} path ${i}`);
    }
    assert.equal(ax.terminal, !!p.terminal, label);
  });

  const nodePos = new Map(g.nodes.map((n) => [n.node, n.pos]));
  for (const ax of g.axes) {
    const where = `${label} path ${ax.path} (${ax.shape})`;
    for (const [end, point, tan, sign] of [
      [ax.a, ax.start, ax.startTangent, -1],
      [ax.b, ax.end, ax.endTangent, 1],
    ] as const) {
      assert.ok(Math.abs(norm(tan) - 1) < TOL, `${where}: unit tangent`);
      if (isEdge(end)) {
        // at the edge midpoint, leaving perpendicular to the edge (tangent = -+ outward normal)
        const m = edgeMidpoint(frame, end.edge);
        assert.ok(near(point, m), `${where}: ends on the midpoint of edge ${end.edge}`);
        const u = frame.unit[end.edge]!;
        assert.ok(Math.abs(dot(tan, u) - sign) < 1e-6, `${where}: perpendicular at edge ${end.edge}`);
      } else {
        // node consistency: every axis meets its node at the node's one position
        assert.ok(near(point, nodePos.get(end.node)!), `${where}: meets node ${end.node}`);
      }
    }
    const chord = norm(sub(ax.end, ax.start));
    if (ax.curve.kind === "line") assert.ok(Math.abs(ax.length - chord) < TOL, `${where}: line length = chord`);
    else if (ax.curve.kind === "arc" || Math.abs(cross(sub(ax.curve.c, ax.curve.p0), sub(ax.curve.p1, ax.curve.p0))) > 1e-6) {
      assert.ok(ax.length > chord + 1e-6, `${where}: curve longer than its chord`);
    } else assert.ok(Math.abs(ax.length - chord) < 1e-6, `${where}: straight Bezier (node in line) as long as its chord`);
    assert.ok(ax.length < 2 * frame.side, `${where}: plausible length ${ax.length}`);
    // stays inside the hex (circumradius = side)
    for (const s of polyline(ax, 0.05)) assert.ok(norm(s) <= frame.side + 1e-6, `${where}: inside the hex`);
  }
  // nodes inside the hex and not on top of each other
  for (const n of g.nodes) assert.ok(norm(n.pos) < frame.inradius, `${label}: node ${n.node} inside`);
  for (const [i, n] of g.nodes.entries()) {
    for (const m of g.nodes.slice(i + 1)) {
      assert.ok(norm(sub(n.pos, m.pos)) > 0.3 * frame.side, `${label}: nodes ${n.node} and ${m.node} apart`);
    }
  }
}

test("edge vectors from /map form a regular hexagon of side 1 and match the neighbour positions", () => {
  assert.ok(Math.abs(frame.inradius - SQRT3 / 2) < 1e-6);
  assert.ok(Math.abs(frame.side - 1) < 1e-6);
  let checked = 0;
  for (const h of fx.hexes) {
    h.neighbors.forEach((nid, i) => {
      const n = nid ? byId.get(nid) : undefined;
      if (!n) return;
      const v = fx.layout.edge_vectors[i]!;
      assert.ok(near({ x: n.x - h.x, y: n.y - h.y }, { x: v[0], y: v[1] }, 1e-5), `${h.id} edge ${i}`);
      checked++;
    });
  }
  assert.ok(checked > 900, `neighbour pairs checked: ${checked}`);
});

test("every catalog tile in all six rotations yields consistent axes", () => {
  const names = Object.keys(fx.tiles);
  assert.equal(names.length, 76);
  let axes = 0;
  for (const name of names) {
    const parts = fx.tiles[name]!;
    for (let r = 0; r < 6; r++) {
      const g = tileGeometry(parts, r, frame);
      checkGeometry(`tile ${name} r${r}`, parts, r, g);
      axes += g.axes.length;
    }
  }
  assert.ok(axes > 1000, `axes: ${axes}`);
});

test("every printed hex with track or nodes yields consistent axes", () => {
  const printed = fx.hexes.filter(hasTrack);
  assert.ok(printed.length > 350, `printed hexes: ${printed.length}`);
  for (const h of printed) checkGeometry(`hex ${h.id}`, h, 0, tileGeometry(h, 0, frame));
});

test("rotation turns the geometry by 60 degrees per step (where placement is rotation-free)", () => {
  const turn = (p: Vec, r: number): Vec => {
    // the rotation that maps edge i onto edge i + r, read from the frame
    const a = Math.atan2(frame.unit[r % 6]!.y, frame.unit[r % 6]!.x) - Math.atan2(frame.unit[0]!.y, frame.unit[0]!.x);
    return { x: p.x * Math.cos(a) - p.y * Math.sin(a), y: p.x * Math.sin(a) + p.y * Math.cos(a) };
  };
  let compared = 0;
  for (const [name, parts] of Object.entries(fx.tiles)) {
    const g0 = tileGeometry(parts, 0, frame);
    if (g0.nodes.some((n) => n.placement === "engineEdge")) continue; // engine prefers edge 0, not rotation-free
    for (let r = 1; r < 6; r++) {
      const g = tileGeometry(parts, r, frame);
      g.axes.forEach((ax, i) => {
        const ax0 = g0.axes[i]!;
        assert.ok(near(ax.start, turn(ax0.start, r)), `${name} r${r} path ${i} start`);
        assert.ok(near(ax.end, turn(ax0.end, r)), `${name} r${r} path ${i} end`);
        assert.ok(near(pointAt(ax, ax.length / 3), turn(pointAt(ax0, ax0.length / 3), r), 1e-6), `${name} r${r} path ${i}`);
        assert.ok(Math.abs(ax.length - ax0.length) < TOL);
        compared++;
      });
      g.nodes.forEach((n, i) => assert.ok(near(n.pos, turn(g0.nodes[i]!.pos, r)), `${name} r${r} node ${n.node}`));
    }
  }
  assert.ok(compared > 500, `compared: ${compared}`);
});

test("known shapes: straight, wide arc radius 1.5, sharp arc radius 0.5, lengths", () => {
  const one = (name: string): Axis => tileGeometry(fx.tiles[name]!, 0, frame).axes[0]!;
  const straight = one("9"); // edge 0 to 3
  assert.equal(straight.shape, "straight");
  assert.ok(Math.abs(straight.length - SQRT3) < TOL);
  assert.ok(near(pointAt(straight, SQRT3 / 2), { x: 0, y: 0 }), "through the centre");
  const wide = one("8"); // edge 0 to 2
  assert.equal(wide.shape, "wideArc");
  assert.ok(wide.curve.kind === "arc" && Math.abs(wide.curve.radius - 1.5) < TOL);
  assert.ok(Math.abs(wide.length - (1.5 * Math.PI) / 3) < TOL);
  const sharp = one("7"); // edge 0 to 1
  assert.equal(sharp.shape, "sharpArc");
  assert.ok(sharp.curve.kind === "arc" && Math.abs(sharp.curve.radius - 0.5) < TOL);
  assert.ok(Math.abs(sharp.length - (0.5 * 2 * Math.PI) / 3) < TOL);
});

test("nodes: OE12 cities apart on their straights, town on a through track, double town marks", () => {
  const oe12 = tileGeometry(fx.tiles["OE12"]!, 0, frame);
  for (const n of oe12.nodes) {
    assert.equal(n.placement, "engineEdge");
    // each city lies on its own straight line, so both its axes are straight
  }
  for (const ax of oe12.axes) assert.ok(Math.abs(cross(ax.startTangent, ax.endTangent)) < 1e-6, "OE12 spokes are straight");

  for (const name of ["3", "4", "58"]) {
    const g = tileGeometry(fx.tiles[name]!, 2, frame);
    assert.equal(g.nodes[0]!.placement, "throughTown", name);
    const [p, q] = g.axes;
    // the track runs through the town without a kink
    const tp = p!.b.hasOwnProperty("node") ? p!.endTangent : p!.startTangent;
    const tq = q!.b.hasOwnProperty("node") ? q!.endTangent : q!.startTangent;
    assert.ok(Math.abs(cross(tp, tq)) < 1e-6, `${name}: no kink at the town`);
  }

  const g = tileGeometry(fx.tiles["OE1"]!, 1, frame);
  const dt = g.nodes[0]!;
  assert.equal(dt.kind, "double_town");
  assert.ok(near(dt.pos, { x: 0, y: 0 }));
  assert.ok(dt.marks && near(add(dt.marks[0], dt.marks[1]), { x: 0, y: 0 }));
  assert.deepEqual(dt.revenueLoc, [2.5, 5.5]);

  const linz = byId.get("R51")!; // town with loc 4.5, no paths
  assert.equal(tileGeometry(linz, 0, frame).nodes[0]!.placement, "loc");
  const aa82 = tileGeometry(byId.get("AA82")!, 0, frame); // 2 cities, one without path: opposite
  assert.ok(near(aa82.nodes[1]!.pos, { x: -aa82.nodes[0]!.pos.x, y: -aa82.nodes[0]!.pos.y }));
  const offboard = tileGeometry(byId.get("B83")!, 0, frame);
  assert.equal(offboard.nodes[0]!.kind, "offboard");
  assert.ok(near(offboard.nodes[0]!.pos, { x: 0, y: 0 }), "off-board anchor in the centre");
  const port = tileGeometry(byId.get("G48")!, 0, frame);
  assert.ok(port.axes.every((ax) => ax.terminal && ax.shape === "toNode"));
});

// Seeded PRNG so a failure is reproducible.
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

test("axes of neighbouring hexes meet continuously at the shared edge (position and tangent)", () => {
  const names = Object.keys(fx.tiles);
  const block = fx.block.map((id) => byId.get(id)!);
  let joints = 0;
  for (let round = 0; round < 20; round++) {
    const rand = rng(round + 1);
    // printed track stays, every other hex in the block gets a random tile and rotation
    const placed = new Map<string, TileGeometry>();
    for (const h of block) {
      if (h.paths) placed.set(h.id, tileGeometry(h, 0, frame));
      else placed.set(h.id, tileGeometry(fx.tiles[names[Math.floor(rand() * names.length)]!]!, Math.floor(rand() * 6), frame));
    }
    for (const h of block) {
      h.neighbors.forEach((nid, i) => {
        const n = nid ? byId.get(nid) : undefined;
        if (!n || !placed.has(n.id) || h.id > n.id) return;
        // the neighbour's edge back to h, read from the data, not assumed to be i + 3
        const j = n.neighbors.indexOf(h.id);
        assert.ok(j >= 0, `${n.id} lists ${h.id} as neighbour`);
        const mine = touching(placed.get(h.id)!, i, { x: h.x, y: h.y });
        const theirs = touching(placed.get(n.id)!, j, { x: n.x, y: n.y });
        for (const a of mine) {
          for (const b of theirs) {
            assert.ok(near(a.point, b.point, 1e-5), `${h.id}/${n.id}: same point on the shared edge`);
            assert.ok(Math.abs(cross(a.tangent, b.tangent)) < 1e-6, `${h.id}/${n.id}: same direction`);
            assert.ok(dot(a.inward, b.inward) < -0.999, `${h.id}/${n.id}: track continues across, no reversal`);
            joints++;
          }
        }
      });
    }
  }
  assert.ok(joints > 200, `joints checked: ${joints}`);
});

/** World point, tangent and inward direction of every axis end on edge `edge` of a placed hex. */
function touching(g: TileGeometry, edge: number, centre: Vec): { point: Vec; tangent: Vec; inward: Vec }[] {
  const out: { point: Vec; tangent: Vec; inward: Vec }[] = [];
  for (const ax of g.axes) {
    if (isEdge(ax.a) && ax.a.edge === edge) out.push({ point: add(ax.start, centre), tangent: ax.startTangent, inward: ax.startTangent });
    if (isEdge(ax.b) && ax.b.edge === edge) {
      out.push({ point: add(ax.end, centre), tangent: ax.endTangent, inward: { x: -ax.endTangent.x, y: -ax.endTangent.y } });
    }
  }
  return out;
}

test("sampling by distance: ends, spacing, tangents", () => {
  for (const [name, parts] of Object.entries(fx.tiles)) {
    for (const ax of tileGeometry(parts, 3, frame).axes) {
      const where = `${name} path ${ax.path}`;
      const a = pointAt(ax, 0);
      const b = pointAt(ax, ax.length);
      assert.ok(near(a, ax.start) && near(b, ax.end), `${where}: ends`);
      assert.ok(near({ x: a.tx, y: a.ty }, ax.startTangent) && near({ x: b.tx, y: b.ty }, ax.endTangent), `${where}: end tangents`);
      assert.ok(near(pointAt(ax, -1), a) && near(pointAt(ax, ax.length + 1), b), `${where}: clamped`);
      const step = 0.1;
      const s = samplesEvery(ax, step);
      assert.equal(s.length, Math.floor((ax.length - step / 2) / step + 1e-9) + 1, where);
      for (let k = 1; k < s.length; k++) {
        const d = norm(sub(s[k]!, s[k - 1]!));
        assert.ok(d <= step + 1e-9 && d > step * 0.98, `${where}: chord ${d} for arc step ${step}`);
      }
      const poly = polyline(ax, 0.05);
      assert.ok(poly.length >= Math.ceil(ax.length / 0.05) + 1, where);
      for (let k = 1; k < poly.length; k++) assert.ok(norm(sub(poly[k]!, poly[k - 1]!)) <= 0.05 + 1e-9, where);
      // tangent agrees with the direction between close samples
      const mid = pointAt(ax, ax.length / 2);
      const next = pointAt(ax, ax.length / 2 + 1e-4);
      const dir = sub(next, mid);
      assert.ok(Math.abs(cross({ x: mid.tx, y: mid.ty }, dir)) / norm(dir) < 1e-3, `${where}: tangent`);
    }
  }
  const ax = tileGeometry(fx.tiles["9"]!, 0, frame).axes[0]!;
  assert.ok(near(pointAt(ax, 0, { x: 10, y: 20 }), add(ax.start, { x: 10, y: 20 })), "origin offset");
});
