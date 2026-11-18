// #460: the slides of the title screen (ui/title-slides.ts): the six board scenes, each file present, and the order of
// advancing.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { SLIDES, nextSlide } from "../ui/title-slides.ts";

const web = new URL("..", import.meta.url).pathname;

test("six slides, the map first, every file exists and is listed once", () => {
  assert.equal(SLIDES.length, 6);
  assert.equal(SLIDES[0]!.scene, "s06-gleis");
  assert.equal(new Set(SLIDES.map((s) => s.scene)).size, SLIDES.length);
  for (const s of SLIDES) assert.ok(existsSync(join(web, "title", `${s.scene}.png`)), `${s.scene}.png missing`);
});

test("nextSlide goes on and wraps round; a chosen slide stays within range", () => {
  assert.equal(nextSlide(0, 6), 1);
  assert.equal(nextSlide(5, 6), 0);
  assert.equal(nextSlide(0, 1), 0);
  assert.equal(nextSlide(9, 6), 4);
});
