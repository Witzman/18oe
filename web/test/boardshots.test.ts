import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { test } from "node:test";
import { loadScenes, pickScenes } from "../../bin/boardshots.mjs";

const scenes = loadScenes();

test("board scenes: unique names, titles, and a recorded game fixture each", () => {
  assert.ok(scenes.length >= 12);
  assert.equal(new Set(scenes.map((s) => s.name)).size, scenes.length);
  for (const s of scenes) {
    assert.match(s.name, /^s\d\d-[a-z-]+$/);
    assert.ok(s.title.length > 0, s.name);
    assert.ok(existsSync(new URL(`./fixtures/games/${s.fixture}.json`, import.meta.url)), `${s.name}: fixture ${s.fixture}`);
    if (s.eval) assert.doesNotThrow(() => new Function(`return ${s.eval}`), `${s.name}: eval parses`);
  }
});

test("pickScenes: all, by name, and a clear error for an unknown name", () => {
  assert.equal(pickScenes(scenes, []).length, scenes.length);
  assert.deepEqual(pickScenes(scenes, ["s01-auktion"]).map((s) => s.name), ["s01-auktion"]);
  assert.throws(() => pickScenes(scenes, ["nope"]), /unknown scene: nope/);
});
