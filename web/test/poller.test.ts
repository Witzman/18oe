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

// #294: a state that cannot be drawn was reported as "no connection", and the poller had already taken its
// seq, so the next check found nothing new, the band vanished and the page kept only the map.
test("a display error is reported as such, keeps the band up and the state is loaded again", async () => {
  const timers: (() => void)[] = [];
  const retry: { ms: number; kind: string; message: string }[] = [];
  const rendered: unknown[] = [];
  let throwing = true;
  let ok = 0;
  let loads = 0;
  const poller = createPoller({
    api: {
      version: async () => ({ seq: 3, status: "active", round: { type: "OR", number: 1, turn: 1 }, acting: [], viewer_to_act: true }),
      getGame: async () => { loads++; return game(3); },
    },
    gameId: 1,
    onGame: (g) => { if (throwing) throw new TypeError("x is undefined"); rendered.push(g.seq); },
    onRenderError: () => {},
    onOk: () => { ok++; },
    onRetryIn: (ms, why) => retry.push({ ms, kind: why.kind, message: why.message }),
    setTimer: (fn) => { timers.push(fn); return timers.length; }, clearTimer: () => {},
  });
  const flush = () => new Promise((r) => setImmediate(r));
  poller.start(); await flush();
  assert.deepEqual(retry, [{ ms: 2000, kind: "render", message: "TypeError: x is undefined" }]);
  assert.equal(ok, 0, "no 'ok' after a failed draw");
  assert.equal(poller.lastSeq, null);
  timers.shift()!(); await flush();
  assert.equal(loads, 2, "same seq, but the state is loaded again because it was never drawn");
  throwing = false;
  timers.shift()!(); await flush();
  assert.deepEqual(rendered, [3]);
  assert.equal(ok, 1);
  assert.equal(poller.lastSeq, 3);
});

test("a server error (5xx) on the state is retried with the band and names request, status and time", async () => {
  const timers: (() => void)[] = [];
  const retry: { kind: string; status: number; request: string }[] = [];
  const errors: number[] = [];
  const poller = createPoller({
    api: {
      version: async () => ({ seq: 1, status: "active", round: { type: "OR", number: 1, turn: 1 }, acting: [], viewer_to_act: false }),
      getGame: async () => { throw new ApiError(502, "http_error", "HTTP 502 Bad Gateway", "GET /games/1", 30012); },
    },
    gameId: 1, onGame: () => {}, onError: (e) => errors.push(e.status),
    onRetryIn: (_ms, why) => retry.push({ kind: why.kind, status: why.status, request: why.request }),
    setTimer: (fn) => { timers.push(fn); return timers.length; }, clearTimer: () => {},
  });
  poller.start(); await new Promise((r) => setImmediate(r));
  assert.deepEqual(retry, [{ kind: "server", status: 502, request: "GET /games/1" }]);
  assert.deepEqual(errors, [502]);
  assert.equal(timers.length, 1);
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
