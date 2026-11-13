import assert from "node:assert/strict";
import { test } from "node:test";
import { ApiError } from "../api.ts";
import { createPoller } from "../poller.ts";
import type { Game } from "../types.ts";

const game = (seq: number) => ({ id: 1, seq } as unknown as Game);

function setup(opts: { versions: (number | ApiError)[]; visible?: () => boolean }) {
  const queue = [...opts.versions];
  let current = 0; // what the fake server reports; getGame returns the same seq
  const log = { loads: 0, versions: 0, games: [] as number[], errors: [] as ApiError[], unauthorized: 0 };
  const timers: (() => void)[] = [];
  const poller = createPoller({
    api: {
      version: async () => {
        log.versions++;
        const next = queue.shift() ?? current;
        if (next instanceof ApiError) throw next;
        current = next;
        return { seq: next, status: "active", round: { type: "OR", number: 1, turn: 1 }, acting: [], viewer_to_act: false };
      },
      getGame: async () => { log.loads++; return game(current); },
    },
    gameId: 1,
    onGame: (g) => log.games.push(g.seq),
    onError: (e) => log.errors.push(e),
    onUnauthorized: () => { log.unauthorized++; },
    isVisible: opts.visible,
    setTimer: (fn) => { timers.push(fn); return timers.length; },
    clearTimer: () => {},
  });
  const flush = () => new Promise((r) => setImmediate(r));
  return { poller, log, timers, flush };
}

test("loads the full state on the first check and only again when seq changes", async () => {
  const { poller, log, timers, flush } = setup({ versions: [4, 4, 5] });
  poller.start();
  await flush();
  assert.equal(log.loads, 1);
  assert.equal(poller.state, "waiting");
  timers.shift()!(); await flush(); // seq 4 again: no reload
  assert.equal(log.loads, 1);
  timers.shift()!(); await flush(); // seq 5: reload
  assert.equal(log.loads, 2);
  assert.equal(log.versions, 3);
});

test("does not poll while the tab is hidden, but keeps the timer going", async () => {
  let visible = false;
  const { poller, log, timers, flush } = setup({ versions: [1], visible: () => visible });
  poller.start(); // first check is forced
  await flush();
  assert.equal(log.versions, 1);
  timers.shift()!(); await flush();
  assert.equal(log.versions, 1, "hidden: no request");
  assert.equal(timers.length, 1, "still rescheduled");
  visible = true;
  timers.shift()!(); await flush();
  assert.equal(log.versions, 2);
});

test("a network error is reported and polling continues", async () => {
  const { poller, log, timers, flush } = setup({ versions: [new ApiError(0, "network", "offline"), 2] });
  poller.start(); await flush();
  assert.equal(log.errors[0]?.code, "network");
  assert.equal(timers.length, 1);
  timers.shift()!(); await flush();
  assert.equal(log.loads, 1);
});

test("401 stops polling and signals the login screen", async () => {
  const { poller, log, timers, flush } = setup({ versions: [new ApiError(401, "login_required", "login")] });
  poller.start(); await flush();
  assert.equal(log.unauthorized, 1);
  assert.equal(poller.state, "stopped");
  assert.equal(timers.length, 0);
});

test("stop prevents any further request and adopt shows an own move at once", async () => {
  const { poller, log, timers, flush } = setup({ versions: [1, 2] });
  poller.start(); await flush();
  poller.adopt(game(7));
  assert.equal(poller.lastSeq, 7);
  poller.stop();
  timers.shift()!(); await flush();
  assert.equal(log.versions, 1);
  assert.deepEqual(log.games, [1, 7]);
});
