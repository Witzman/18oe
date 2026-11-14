import assert from "node:assert/strict";
import { test } from "node:test";
import { ApiError, createApi, type FetchLike } from "../api.ts";

function fake(status: number, body: unknown, calls: { path: string; init?: RequestInit }[] = []): FetchLike {
  return async (path, init) => {
    calls.push({ path, init });
    return new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
  };
}

test("GET sends credentials and parses JSON", async () => {
  const calls: { path: string; init?: RequestInit }[] = [];
  const api = createApi(fake(200, { seq: 5, status: "active" }, calls));
  assert.deepEqual(await api.version(3), { seq: 5, status: "active" });
  assert.equal(calls[0]?.path, "/games/3/version");
  assert.equal(calls[0]?.init?.method, "GET");
  assert.equal(calls[0]?.init?.credentials, "same-origin");
  assert.equal(calls[0]?.init?.body, undefined);
});

test("POST /games sends the seats as JSON", async () => {
  const calls: { path: string; init?: RequestInit }[] = [];
  const api = createApi(fake(201, { id: 1 }, calls));
  await api.createGame([{ kind: "human", account_id: "alice" }, { kind: "bot" }]);
  assert.equal(calls[0]?.init?.method, "POST");
  assert.deepEqual(JSON.parse(String(calls[0]?.init?.body)), { seats: [{ kind: "human", account_id: "alice" }, { kind: "bot" }] });
  assert.equal((calls[0]?.init?.headers as Record<string, string>)["Content-Type"], "application/json");
});

test("postAction sends action and seq", async () => {
  const calls: { path: string; init?: RequestInit }[] = [];
  await createApi(fake(200, {}, calls)).postAction(2, { type: "pass" }, 9);
  assert.equal(calls[0]?.path, "/games/2/actions");
  assert.deepEqual(JSON.parse(String(calls[0]?.init?.body)), { action: { type: "pass" }, seq: 9 });
});

test("register sends name, e-mail, password and code in the POST body, never in a URL", async () => {
  const calls: { path: string; init?: RequestInit }[] = [];
  const me = await createApi(fake(201, { id: "u1", name: "Anna" }, calls))
    .register({ name: "Anna", email: "a@b.de", password: "geheim123", code: "einlass" });
  assert.deepEqual(me, { id: "u1", name: "Anna" });
  assert.equal(calls[0]?.path, "/register");
  assert.equal(calls[0]?.init?.method, "POST");
  assert.deepEqual(JSON.parse(String(calls[0]?.init?.body)), { name: "Anna", email: "a@b.de", password: "geheim123", code: "einlass" });
});

test("login sends login and password to POST /login", async () => {
  const calls: { path: string; init?: RequestInit }[] = [];
  await createApi(fake(200, { id: "u1", name: "Anna" }, calls)).login("Anna", "geheim123");
  assert.equal(calls[0]?.path, "/login");
  assert.equal(calls[0]?.init?.method, "POST");
  assert.deepEqual(JSON.parse(String(calls[0]?.init?.body)), { login: "Anna", password: "geheim123" });
});

test("a failed login is an ApiError with the server code", async () => {
  const api = createApi(fake(401, { error: "invalid_login", message: "invalid login or password" }));
  await assert.rejects(api.login("x", "y"), (e: unknown) => e instanceof ApiError && e.status === 401 && e.code === "invalid_login");
});

test("server errors become ApiError with status and code", async () => {
  const api = createApi(fake(409, { error: "conflict", message: "stale" }));
  await assert.rejects(api.postAction(1, {}, 1), (e: unknown) =>
    e instanceof ApiError && e.status === 409 && e.code === "conflict" && e.message === "stale");
});

test("non-JSON error bodies still give an ApiError", async () => {
  await assert.rejects(createApi(fake(502, "<html>bad gateway</html>")).me(), (e: unknown) =>
    e instanceof ApiError && e.status === 502 && e.code === "http_error");
});

test("a failed fetch is reported as a network error", async () => {
  const api = createApi(async () => { throw new TypeError("offline"); });
  await assert.rejects(api.me(), (e: unknown) => e instanceof ApiError && e.status === 0 && e.code === "network");
});

test("resetPassword sends only the e-mail to POST /reset-password (#282)", async () => {
  const calls: { path: string; init?: RequestInit }[] = [];
  const r = await createApi(fake(200, { password: "abc123XYZ789qw" }, calls)).resetPassword("a@b.de");
  assert.equal(r.password, "abc123XYZ789qw");
  assert.equal(calls[0]?.path, "/reset-password");
  assert.equal(calls[0]?.init?.method, "POST");
  assert.deepEqual(JSON.parse(String(calls[0]?.init?.body)), { email: "a@b.de" });
});

// #294: the band names the request, its status and the elapsed time; a hanging GET ends as a timeout.
test("errors carry the request and the elapsed time; a hanging GET is aborted as a timeout", async () => {
  let t = 0;
  const now = () => t;
  const slow: FetchLike = async () => { t += 1234; return new Response("<html>Bad Gateway</html>", { status: 502, statusText: "Bad Gateway" }); };
  const e1 = await createApi(slow, { now }).getGame(1).catch((e: unknown) => e) as ApiError;
  assert.equal(e1.status, 502);
  assert.equal(e1.request, "GET /games/1");
  assert.equal(e1.elapsedMs, 1234);
  assert.match(e1.message, /502 Bad Gateway/);

  const hang: FetchLike = (_p, init) => new Promise((_r, reject) => {
    init?.signal?.addEventListener("abort", () => reject(new DOMException("The operation was aborted.", "AbortError")));
  });
  const e2 = await createApi(hang, { getTimeoutMs: 20 }).getGame(1).catch((e: unknown) => e) as ApiError;
  assert.equal(e2.status, 0);
  assert.equal(e2.code, "timeout");
  assert.equal(e2.request, "GET /games/1");
});

test("a 200 without JSON (cut-off body, proxy page) is an error, not an empty state", async () => {
  const e = await createApi(fake(200, "<html>")).getGame(1).catch((x: unknown) => x) as ApiError;
  assert.equal(e.code, "bad_response");
});

test("an action whose answer never comes fails as a network error after the timeout (#289)", async () => {
  const hang: FetchLike = (_path, init) => new Promise((_resolve, reject) => {
    init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
  });
  const api = createApi(hang, { postTimeoutMs: 30 });
  await assert.rejects(api.postAction(1, { type: "pass" }, 3), (e: unknown) => e instanceof ApiError && e.status === 0 && e.message === "timeout");
  // reads have their own, longer limit (GET_TIMEOUT_MS, #294)
  let resolved = false;
  const slow: FetchLike = () => new Promise((r) => setTimeout(() => { resolved = true; r(new Response(JSON.stringify({ seq: 1 }), { status: 200 })); }, 60));
  assert.deepEqual(await createApi(slow, { postTimeoutMs: 30 }).version(1), { seq: 1 });
  assert.ok(resolved);
});
