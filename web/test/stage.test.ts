// The stage state machine of the action box (#497 S2), pure under node.
import assert from "node:assert/strict";
import { test } from "node:test";
import { backStage, chooseKind, stageAfterRender, stageView } from "../ui/frame/stage.ts";

test("several kinds: step 1 shows only the kinds, choosing one gives step 2 with back, back returns to step 1", () => {
  const kinds = ["remove_regional", "private_close"] as const;
  assert.deepEqual(stageView(kinds, null), { step: 1, kind: null, back: false });
  const s = chooseKind(kinds, null, "private_close");
  assert.deepEqual(stageView(kinds, s), { step: 2, kind: "private_close", back: true });
  assert.deepEqual(stageView(kinds, backStage()), { step: 1, kind: null, back: false });
});

test("a single kind skips step 1 and has no back", () => {
  assert.deepEqual(stageView(["pass"], null), { step: 2, kind: "pass", back: false });
  assert.deepEqual(stageView(["pass"], "pass"), { step: 2, kind: "pass", back: false });
});

test("nothing offered: step 2 without kind", () => {
  assert.deepEqual(stageView([], null), { step: 2, kind: null, back: false });
});

test("a chosen kind that is no longer offered falls back to step 1; choosing an unoffered kind changes nothing", () => {
  assert.deepEqual(stageView(["buy", "sell"], "pass"), { step: 1, kind: null, back: false });
  assert.equal(chooseKind(["buy", "sell"], null, "pass"), null);
  assert.equal(chooseKind(["buy", "sell"], "buy", "pass"), "buy");
});

test("a new seq drops the stage, the same seq (rotation) and the first render keep the rules", () => {
  assert.equal(stageAfterRender("buy", 5, 5), "buy");
  assert.equal(stageAfterRender("buy", 5, 6), null);
  assert.equal(stageAfterRender("buy", null, 6), null);
});
