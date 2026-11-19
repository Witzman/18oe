// #451: the ports of the map as anchor marks (render/ports.ts): one mark per `ports` entry that names a kind (public
// or private), on its hex side or, for an offshore port, in the middle of its sea hex. Ferry ends and dead ends
// without a kind are no ports.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { portMarks } from "../render/ports.ts";

const here = dirname(fileURLToPath(import.meta.url));
const geometry = JSON.parse(readFileSync(join(here, "fixtures", "map-geometry.json"), "utf8"));

test("one mark per port with a kind: 30+10 public and 23+5 private on a side, 10 public and 2 private offshore", () => {
  const marks = portMarks(geometry.ports);
  const count = (kind: string, offshore: boolean) => marks.filter((m) => m.kind === kind && (m.side === "offshore") === offshore).length;
  assert.equal(count("public", false), 40);
  assert.equal(count("private", false), 28);
  assert.equal(count("public", true), 10);
  assert.equal(count("private", true), 2);
  assert.equal(marks.length, 80);
});

test("a ferry end or dead end without a kind makes no mark; a port that is also a ferry end does", () => {
  const marks = portMarks([
    { hex: "A1", edge: 0, ferries: [{ hex: "B2", exit: 3, distance: 0 }] },
    { hex: "A2", edge: 1, dead_end: true },
    { hex: "AD7", edge: 5, port: "public" },
    { hex: "G26", edge: "offshore", port: "private", ferries: [{ hex: "B41", exit: 1, distance: 1 }] },
  ]);
  assert.deepEqual(marks, [
    { hex: "AD7", side: 5, kind: "public" },
    { hex: "G26", side: "offshore", kind: "private" },
  ]);
});

test("an unknown kind is ignored, so a new kind in the data cannot draw a wrong anchor", () => {
  assert.deepEqual(portMarks([{ hex: "A1", edge: 2, port: "royal" }]), []);
});

// #459: the mark sits at a corner of its side, the one whose other hex is water (so it lies between possible tracks).
import { portCornerSide } from "../render/ports.ts";

test("the corner next to the sea hex is chosen; with both or neither, the higher side", () => {
  const kinds = (sea: number[]) => (i: number) => (sea.includes(((i % 6) + 6) % 6) ? "sea" : "land");
  assert.equal(portCornerSide(2, kinds([1])), 1);
  assert.equal(portCornerSide(2, kinds([3])), 3);
  assert.equal(portCornerSide(2, kinds([1, 3])), 3);
  assert.equal(portCornerSide(2, kinds([])), 3);
  assert.equal(portCornerSide(5, kinds([0])), 0);
  assert.equal(portCornerSide(0, kinds([5])), 5);
});
