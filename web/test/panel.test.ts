import assert from "node:assert/strict";
import { test } from "node:test";
import { COLLAPSED_KEY, panelIdle, readCollapsed, writeCollapsed } from "../ui/frame/panel.ts";

function memory() {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), removeItem: (k: string) => void m.delete(k), m };
}

test("collapsed state of the action panel is remembered and defaults to open", () => {
  const st = memory();
  assert.equal(readCollapsed(st), false);
  writeCollapsed(true, st);
  assert.equal(st.m.get(COLLAPSED_KEY), "1");
  assert.equal(readCollapsed(st), true);
  writeCollapsed(false, st);
  assert.equal(readCollapsed(st), false);
});

test("a storage that throws or is missing never breaks the panel", () => {
  const bad = { getItem: () => { throw new Error("blocked"); }, setItem: () => { throw new Error("blocked"); }, removeItem: () => { throw new Error("blocked"); } };
  assert.equal(readCollapsed(bad), false);
  assert.doesNotThrow(() => writeCollapsed(true, bad));
  assert.equal(readCollapsed(null), false);
  assert.doesNotThrow(() => writeCollapsed(true, null));
});

test("panel idle (#370): only when nothing at all would show; any single thing keeps the panel", () => {
  const none = { order: false, selected: false, generic: false, context: false, message: false, stall: false };
  assert.equal(panelIdle(none), true);
  for (const k of Object.keys(none) as (keyof typeof none)[]) assert.equal(panelIdle({ ...none, [k]: true }), false, k);
});
