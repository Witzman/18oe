import assert from "node:assert/strict";
import { test } from "node:test";
import { fetchLogFrom, isAtBottom, mergeLog, nextScrollTop, resumeFrom } from "../ui/frame/log.ts";

const L = (action: number, text = `t${action}`) => ({ action, text });

test("mergeLog appends and replaces lines of the overlapping action", () => {
  assert.deepEqual(mergeLog([L(1), L(2)], [L(3)]), [L(1), L(2), L(3)]);
  assert.deepEqual(mergeLog([L(1), L(2, "a")], [L(2, "b"), L(2, "c"), L(3)]), [L(1), L(2, "b"), L(2, "c"), L(3)]);
  assert.deepEqual(mergeLog([L(1)], []), [L(1)]);
});

test("fetchLogFrom follows pages and never splits an action", async () => {
  const all = [L(1), L(2), L(2, "x"), L(3), L(4), L(4, "y"), L(5)];
  const page = async (from: number) => {
    const rest = all.filter((l) => l.action > from);
    const lines = rest.slice(0, 3);
    return { lines, next: rest.length > 3 ? lines[2]!.action : null, seq: 9 };
  };
  assert.deepEqual(await fetchLogFrom(page, 0), all);
});

test("resumeFrom and scroll rules", () => {
  assert.equal(resumeFrom([]), 0);
  assert.equal(resumeFrom([L(1), L(7)]), 6);
  assert.equal(nextScrollTop({ top: 10, atBottom: true }, 500, 100), 400);
  assert.equal(nextScrollTop({ top: 10, atBottom: false }, 500, 100), 10);
  assert.equal(isAtBottom(400, 500, 100), true);
  assert.equal(isAtBottom(100, 500, 100), false);
});
