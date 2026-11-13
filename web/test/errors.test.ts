// Server errors and connection loss (#162, ui-spec §3.6): each case with a faked fetch through the
// real api wrapper and the real session. DOM pieces (band, message area) are checked in the browser
// screenshot pass; here only the logic.
import assert from "node:assert/strict";
import { test } from "node:test";
import { ApiError, createApi, type FetchLike } from "../api.ts";
import { createPoller } from "../poller.ts";
import { createSession } from "../session.ts";
import type { Game } from "../types.ts";
import { classify } from "../ui/errors.ts";
import { txt } from "../ui/text.ts";

const game = (seq: number) => ({ id: 1, seq } as unknown as Game);
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function setup(post: () => Response | Promise<Response>, reload: Response = json(200, game(9))) {
  const calls: { url: string; body?: unknown }[] = [];
  const fetchFn: FetchLike = async (url, init) => {
    calls.push({ url, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    if (init?.method === "POST") return post();
    return reload.clone();
  };
  const log = { said: [] as [string, string][], cleared: 0, busy: [] as boolean[], discarded: 0, unauthorized: 0, notFound: 0, warned: [] as unknown[][], adopted: [] as number[], paused: 0, resumed: 0 };
  const session = createSession({
    api: createApi(fetchFn), gameId: 1,
    poller: { pause: () => { log.paused++; }, resume: () => { log.resumed++; }, adopt: (g) => { log.adopted.push(g.seq); } },
    say: (t, tone) => { log.said.push([t, tone]); }, clearMessage: () => { log.cleared++; }, setBusy: (b) => { log.busy.push(b); },
    discardSelection: () => { log.discarded++; }, onUnauthorized: () => { log.unauthorized++; }, onNotFound: () => { log.notFound++; },
    warn: (...a) => { log.warned.push(a); },
  });
  return { session, log, calls };
}
const action = { type: "pass" };
const reloads = (calls: { url: string }[]) => calls.filter((c) => c.url.includes("?log")).length;

test("success: sends action with the selection's seq, adopts the full state, pauses the poller meanwhile", async () => {
  const { session, log, calls } = setup(() => json(200, game(5)));
  const g = await session.send(action, 4);
  assert.equal(g?.seq, 5);
  assert.deepEqual(calls[0]!.body, { action, seq: 4 });
  assert.deepEqual(log.adopted, [5]);
  assert.equal(log.paused, 1);
  assert.equal(log.resumed, 1);
  assert.deepEqual(log.busy, [true, false]);
  assert.equal(log.cleared, 1);
});

test("422 rejected: engine text unchanged, selection stays, no reload, console.warn with the action", async () => {
  const { session, log, calls } = setup(() => json(422, { error: "rejected", message: "You cannot afford it" }));
  assert.equal(await session.send(action, 4), null);
  assert.deepEqual(log.said, [[txt("msg.rejected").de.replace("{message}", "You cannot afford it"), "error"]]);
  assert.equal(log.discarded, 0);
  assert.equal(reloads(calls), 0);
  assert.equal(log.warned.length, 1);
  assert.deepEqual(log.warned[0]![1], action);
  assert.equal(log.resumed, 1);
});

test("409 conflict: selection dropped, state reloaded, warning tone", async () => {
  const { session, log, calls } = setup(() => json(409, { error: "conflict", message: "stale" }));
  await session.send(action, 4);
  assert.deepEqual(log.said, [[txt("msg.conflict").de, "warn"]]);
  assert.equal(log.discarded, 1);
  assert.equal(reloads(calls), 1);
  assert.deepEqual(log.adopted, [9]);
});

test("403: selection dropped, state reloaded, not-your-turn text", async () => {
  const { session, log } = setup(() => json(403, { error: "not_your_turn", message: "x" }));
  await session.send(action, 4);
  assert.deepEqual(log.said, [[txt("msg.not_your_turn").de, "error"]]);
  assert.equal(log.discarded, 1);
  assert.deepEqual(log.adopted, [9]);
});

test("401: goes to login, no message", async () => {
  const { session, log } = setup(() => json(401, { error: "login_required", message: "x" }));
  await session.send(action, 4);
  assert.equal(log.unauthorized, 1);
  assert.deepEqual(log.said, []);
});

test("400: program error text, logged, state reloaded", async () => {
  const { session, log } = setup(() => json(400, { error: "bad_request", message: "bad seq" }));
  await session.send(action, 4);
  assert.deepEqual(log.said, [[txt("msg.bad_request").de.replace("{message}", "bad seq"), "error"]]);
  assert.equal(log.warned.length, 1);
  assert.deepEqual(log.adopted, [9]);
});

test("404: not-found page, no message", async () => {
  const { session, log } = setup(() => json(404, { error: "not_found", message: "x" }));
  await session.send(action, 4);
  assert.equal(log.notFound, 1);
  assert.deepEqual(log.said, []);
});

test("network lost: selection stays, nothing reloaded, action is not resent", async () => {
  let posts = 0;
  const { session, log } = setup(() => { posts++; throw new TypeError("fetch failed"); });
  assert.equal(await session.send(action, 4), null);
  assert.equal(posts, 1);
  assert.deepEqual(log.said, [[txt("msg.network_action").de, "error"]]);
  assert.equal(log.discarded, 0);
  assert.equal(log.adopted.length, 0);
  assert.equal(log.resumed, 1);
});

test("a second send while one is in flight is ignored (no double sending)", async () => {
  let release!: (r: Response) => void;
  const { session, calls } = setup(() => new Promise<Response>((r) => { release = r; }));
  const first = session.send(action, 4);
  assert.equal(await session.send(action, 4), null);
  release(json(200, game(5)));
  await first;
  assert.equal(calls.filter((c) => c.body !== undefined).length, 1);
});

test("unknown server error (500): shown, no discard", () => {
  const o = classify(new ApiError(500, "internal_error", "boom"));
  assert.equal(o.kind, "server");
  assert.equal(o.discardSelection, false);
});

test("poller: pauses while an action is in flight; reports network loss with the retry time and recovery", async () => {
  const log = { versions: 0, retry: [] as number[], ok: 0 };
  let fail = true;
  const timers: (() => void)[] = [];
  const poller = createPoller({
    api: {
      version: async () => { log.versions++; if (fail) throw new ApiError(0, "network", "x"); return { seq: 1, status: "active", round: { type: "OR", number: 1, turn: 1 }, acting: [], viewer_to_act: false }; },
      getGame: async () => game(1),
    },
    gameId: 1, activeMs: 5000, onGame: () => {}, onOk: () => { log.ok++; }, onRetryIn: (ms) => log.retry.push(ms),
    setTimer: (fn) => { timers.push(fn); return timers.length; }, clearTimer: () => {},
  });
  const flush = () => new Promise((r) => setImmediate(r));
  poller.start();
  await flush();
  assert.deepEqual(log.retry, [5000]);
  assert.equal(log.ok, 0);
  poller.pause();
  timers.shift()!();
  await flush();
  assert.equal(log.versions, 1, "paused: no request");
  poller.resume();
  fail = false;
  timers.shift()!();
  await flush();
  assert.equal(log.versions, 2);
  assert.equal(log.ok, 1);
});
