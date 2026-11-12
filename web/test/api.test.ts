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

test("the access code goes to POST /accounts, never into a URL", async () => {
  const calls: { path: string; init?: RequestInit }[] = [];
  await createApi(fake(200, { accounts: [] }, calls)).accounts("geheim");
  assert.equal(calls[0]?.path, "/accounts");
  assert.equal(calls[0]?.init?.method, "POST");
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
