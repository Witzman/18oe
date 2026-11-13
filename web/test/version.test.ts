// Versionsangabe (#271): reine Funktionen von ui/version.ts und die Texte dazu.
import assert from "node:assert/strict";
import { test } from "node:test";
import { fetchServerVersion, isStale, versionLine } from "../ui/version.ts";

const server = { version: "0.1.0-dev", build: "abcdef123456", engine: "06b3f0b37+abcdef123456" };

test("versionLine names version, build and engine; missing server values read as unknown", () => {
  assert.equal(versionLine(server, "0.1.0-dev"), "Version 0.1.0-dev · Build abcdef123456 · Engine 06b3f0b37+abcdef123456");
  assert.equal(versionLine(null, "0.1.0-dev"), "Version 0.1.0-dev · Build unbekannt · Engine unbekannt");
});

test("isStale only when both versions are known and differ", () => {
  assert.equal(isStale(server, "0.1.0-dev"), false);
  assert.equal(isStale(server, "0.0.9"), true);
  assert.equal(isStale(null, "0.1.0-dev"), false);
  assert.equal(isStale(server, "dev"), false); // not built through build.mjs (tests)
});

test("fetchServerVersion reads /healthz and swallows every failure", async () => {
  const ok = async (path: string) => { assert.equal(path, "/healthz"); return new Response(JSON.stringify({ status: "ok", ...server })); };
  assert.deepEqual(await fetchServerVersion(ok), { status: "ok", ...server });
  assert.equal(await fetchServerVersion(async () => new Response("", { status: 500 })), null);
  assert.equal(await fetchServerVersion(async () => { throw new Error("offline"); }), null);
  assert.equal(await fetchServerVersion(async () => new Response("not json")), null);
});
