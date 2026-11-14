import assert from "node:assert/strict";
import { test } from "node:test";
import { failureText } from "../ui/connection.ts";

// #294: the band says what failed, not only "no connection".
test("the band text names request, status, time and message per kind", () => {
  assert.equal(failureText({ kind: "server", status: 502, request: "GET /games/1", elapsedMs: 30012, message: "HTTP 502 Bad Gateway" }),
    "Serverfehler HTTP 502 (GET /games/1, 30,0 s: HTTP 502 Bad Gateway)");
  assert.equal(failureText({ kind: "timeout", status: 0, request: "GET /games/1", elapsedMs: 30000, message: "" }),
    "Server antwortet nicht (GET /games/1: keine Antwort nach 30,0 s)");
  assert.equal(failureText({ kind: "network", status: 0, request: "GET /games/1/version", elapsedMs: 15, message: "NetworkError when attempting to fetch resource." }),
    "Keine Verbindung (GET /games/1/version, nach 0,0 s: NetworkError when attempting to fetch resource.)");
  assert.equal(failureText({ kind: "render", status: 0, request: "", elapsedMs: null, message: "TypeError: x is undefined" }),
    "Anzeigefehler: TypeError: x is undefined");
});
