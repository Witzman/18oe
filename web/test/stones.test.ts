// Cities, towns, off-boards and tokens as pieces (#147): slot positions per slot count, hit areas, bars, wedges, revenue.
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  citySlots, hitSlot, medallionExtent, offboardWedges, revenueAll, revenueNow, slotOffsets, SLOT_OVERLAP, townBar, townBars,
} from "../render/stones.ts";
import { hexFrame, tileGeometry, type NodeGeom } from "../render/track-axes.ts";

const R = 0.17;
const d = (a: { x: number; y: number }, b: { x: number; y: number }) => Math.hypot(a.x - b.x, a.y - b.y);
const frame = hexFrame([[0, Math.sqrt(3)], [1.5, Math.sqrt(3) / 2], [1.5, -Math.sqrt(3) / 2], [0, -Math.sqrt(3)], [-1.5, -Math.sqrt(3) / 2], [-1.5, Math.sqrt(3) / 2]]);

test("slot positions: 1 centre, 2 pill, 3 triangle, 4 square, all centred on the node", () => {
  for (const n of [1, 2, 3, 4, 5]) {
    const s = slotOffsets(n, R);
    assert.equal(s.length, n);
    const cx = s.reduce((a, p) => a + p.x, 0) / n, cy = s.reduce((a, p) => a + p.y, 0) / n;
    assert.ok(Math.abs(cx) < 1e-9 && Math.abs(cy) < 1e-9, `${n} slots are centred`);
  }
  assert.deepEqual(slotOffsets(1, R), [{ x: 0, y: 0 }]);
  const pill = slotOffsets(2, R);
  assert.equal(pill[0]!.y, 0);
  assert.ok(Math.abs(d(pill[0]!, pill[1]!) - SLOT_OVERLAP * R) < 1e-9);
  const tri = slotOffsets(3, R);
  assert.ok(tri[0]!.y < tri[1]!.y && Math.abs(tri[1]!.y - tri[2]!.y) < 1e-9, "apex up");
  for (const [a, b] of [[0, 1], [1, 2], [0, 2]] as const) assert.ok(Math.abs(d(tri[a]!, tri[b]!) - SLOT_OVERLAP * R) < 1e-9);
  const sq = slotOffsets(4, R);
  assert.ok(Math.abs(d(sq[0]!, sq[1]!) - SLOT_OVERLAP * R) < 1e-9 && Math.abs(d(sq[0]!, sq[2]!) - SLOT_OVERLAP * R) < 1e-9);
  assert.deepEqual(slotOffsets(0, R), []);
});

test("slots of neighbouring circles overlap a little (one plate) but never swallow each other", () => {
  for (const n of [2, 3, 4]) {
    const s = slotOffsets(n, R);
    for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) assert.ok(d(s[i]!, s[j]!) >= 1.4 * R, `${n}: ${i}/${j} apart`);
  }
  assert.ok(medallionExtent(2, R) > medallionExtent(1, R));
});

test("citySlots: one slot per printed slot, per city index, at the node; tokens may enlarge a city", () => {
  const parts = { cities: [{ node: 0, slots: 2 }, { node: 1, slots: 1 }], paths: [{ a: { edge: 0 }, b: { node: 0 } }, { a: { edge: 3 }, b: { node: 1 } }] };
  const geom = tileGeometry(parts, 0, frame);
  const slots = citySlots(parts, geom.nodes, R);
  assert.deepEqual(slots.map((s) => [s.city, s.slot]), [[0, 0], [0, 1], [1, 0]]);
  const n0 = geom.nodes.find((n) => n.node === 0)!;
  assert.ok(Math.abs((slots[0]!.pos.x + slots[1]!.pos.x) / 2 - n0.pos.x) < 1e-9);
  assert.equal(citySlots(parts, geom.nodes, R, [3]).filter((s) => s.city === 0).length, 3);
});

test("hit areas: the slot circle (at least minHit), the nearest slot wins, a miss is null", () => {
  const slots = citySlots({ cities: [{ node: 0, slots: 3 }] }, [{ node: 0, kind: "city", pos: { x: 0, y: 0 }, placement: "center" } as NodeGeom], R);
  assert.equal(slots.length, 3);
  for (const s of slots) assert.equal(hitSlot(slots, s.pos, R)?.slot, s.slot, "own centre");
  assert.equal(hitSlot(slots, { x: 5, y: 5 }, R), null);
  const edge = { x: slots[0]!.pos.x + R * 0.9, y: slots[0]!.pos.y };
  assert.equal(hitSlot(slots, edge, R)?.slot, 0);
  const off = { x: slots[0]!.pos.x, y: slots[0]!.pos.y - R * 1.5 };
  assert.equal(hitSlot(slots, off, R), null);
  assert.equal(hitSlot(slots, off, R, R * 2)?.slot, 0, "a larger minimum catches it");
});

test("a town bar is a rectangle across the track at the node", () => {
  const bar = townBar({ x: 1, y: 2 }, { x: 1, y: 0 }, 0.34, 0.07);
  const xs = [bar[0]!, bar[2]!, bar[4]!, bar[6]!], ys = [bar[1]!, bar[3]!, bar[5]!, bar[7]!];
  assert.ok(Math.abs(Math.max(...xs) - Math.min(...xs) - 0.07) < 1e-9, "narrow along the track");
  assert.ok(Math.abs(Math.max(...ys) - Math.min(...ys) - 0.34) < 1e-9, "long across it");
  assert.equal(townBar({ x: 0, y: 0 }, null, 0.3, 0.1).length, 8, "no track: horizontal default");
});

test("double town: two bars either side of the centre across the through track; a junction has none", () => {
  const parts = { double_towns: [{ node: 0, axis: 0 }], paths: [{ a: { edge: 0 }, b: { node: 0 } }, { a: { edge: 3 }, b: { node: 0 } }] };
  const geom = tileGeometry(parts, 0, frame);
  const bars = townBars(geom.nodes, geom.axes, 0.34, 0.07);
  assert.equal(bars.length, 2);
  const centre = (b: number[]) => ({ x: (b[0]! + b[4]!) / 2, y: (b[1]! + b[5]!) / 2 });
  assert.ok(Math.abs(centre(bars[0]!).x + centre(bars[1]!).x) < 1e-9 && Math.abs(centre(bars[0]!).y + centre(bars[1]!).y) < 1e-9);
  assert.equal(townBars([{ node: 0, kind: "junction", pos: { x: 0, y: 0 }, placement: "center" }], [], 0.3, 0.1).length, 0);
});

test("an off-board has one wedge per entering track: base on the edge, tip at the node", () => {
  const parts = { offboards: [{ node: 0 }], paths: [{ a: { edge: 1 }, b: { node: 0 }, terminal: true }, { a: { edge: 2 }, b: { node: 0 }, terminal: true }] };
  const geom = tileGeometry(parts, 0, frame);
  const wedges = offboardWedges(geom.nodes[0]!, geom.axes, frame);
  assert.equal(wedges.length, 2);
  for (const w of wedges) {
    assert.equal(w.length, 6);
    assert.ok(Math.abs(Math.hypot((w[2]! + w[4]!) / 2, (w[3]! + w[5]!) / 2) - frame.inradius) < 1e-9, "base midpoint on the edge");
  }
});

test("revenue: a number, the value of the newest open colour, or all phases for an off-board", () => {
  const rev = { yellow: 30, green: 50, brown: 80, gray: 100 };
  assert.equal(revenueNow(20, ["yellow"]), 20);
  assert.equal(revenueNow(rev, ["yellow"]), 30);
  assert.equal(revenueNow(rev, ["yellow", "green"]), 50);
  assert.equal(revenueNow({ green: 60, brown: 100 }, ["yellow"]), 60, "before the first listed colour: the first value");
  assert.equal(revenueNow(undefined, ["yellow"]), null);
  assert.equal(revenueAll(rev), "30/50/80/100");
  assert.equal(revenueAll({ green: 60, gray: 160 }), "60/160");
  assert.equal(revenueAll(0), "0");
});
