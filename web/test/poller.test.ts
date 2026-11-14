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
  const delays: number[] = [];
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
    setTimer: (fn, ms) => { timers.push(fn); delays.push(ms); return timers.length; },
    clearTimer: () => {},
  });
  const flush = () => new Promise((r) => setImmediate(r));
  return { poller, log, timers, delays, flush };
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

test("polls every 2 s while visible and every 10 s in the background, switching without a restart", async () => {
  let visible = true;
  const { poller, log, timers, delays, flush } = setup({ versions: [1, 1, 1], visible: () => visible });
  poller.start(); await flush();
  assert.deepEqual(delays, [2000]);
  visible = false;
  timers.shift()!(); await flush();
  assert.equal(log.versions, 2, "hidden: still checks (title and favicon stay current)");
  assert.deepEqual(delays, [2000, 10000]);
  visible = true;
  timers.shift()!(); await flush();
  assert.deepEqual(delays, [2000, 10000, 2000]);
});

test("tick() right away (tab visible again) checks at once, without waiting for the timer", async () => {
  const { poller, log, timers, flush } = setup({ versions: [1, 2] });
  poller.start(); await flush();
  await poller.tick(); await flush();
  assert.equal(log.versions, 2);
  assert.equal(log.loads, 2);
  assert.equal(poller.state, "waiting");
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

test("a load that started before the player's own action and answers after it does not go back (#289)", async () => {
  let release: (g: Game) => void = () => {};
  const shown: number[] = [];
  const poller = createPoller({
    api: {
      version: async () => ({ seq: 5, status: "active", round: { type: "concession", number: 1, turn: 1 }, acting: [], viewer_to_act: true }),
      getGame: () => new Promise<Game>((r) => { release = r; }),
    },
    gameId: 1,
    onGame: (g) => shown.push(g.seq),
    setTimer: () => 1,
    clearTimer: () => {},
  });
  poller.start();
  await new Promise((r) => setImmediate(r)); // the check runs, the full load (seq 5) is in flight
  poller.adopt(game(6)); // the answer of the player's own action
  release(game(5)); // the old load answers late
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(shown, [6]);
  assert.equal(poller.lastSeq, 6);
});
