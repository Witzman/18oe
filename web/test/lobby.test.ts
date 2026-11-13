import assert from "node:assert/strict";
import { test } from "node:test";
import { ApiError } from "../api.ts";
import { buildSeats, errorText, parseSeed, validateForm, type SeatDraft } from "../ui/lobby.ts";
import { txt } from "../ui/text.ts";

const me = { id: "a1", name: "Anna" };
const bot: SeatDraft = { kind: "bot", account: "" };
const human = (account: string): SeatDraft => ({ kind: "human", account });

test("seats: creator holds seat 1 by id, bots and named humans follow", () => {
  assert.deepEqual(buildSeats(me, [bot, human(" Ben "), human("c@x.de")]), [
    { kind: "human", account_id: "a1" }, { kind: "bot" },
    { kind: "human", account: "Ben" }, { kind: "human", account: "c@x.de" },
  ]);
});

test("validation: empty human seat, double player (case-insensitive, also the creator), seed form", () => {
  assert.equal(validateForm(me, [bot, bot], ""), null);
  assert.match(validateForm(me, [bot, human("  ")], "")!, /Platz 3/);
  assert.match(validateForm(me, [human("Ben"), human("ben")], "")!, /Platz 3/);
  assert.match(validateForm(me, [human("anna")], "")!, /Platz 2/);
  assert.equal(validateForm(me, [bot], "42"), null);
  assert.equal(validateForm(me, [bot], "-1"), txt("lobby.err_seed").de);
  assert.equal(validateForm(me, [bot], "4x"), txt("lobby.err_seed").de);
});

test("seed: empty means random (undefined), otherwise the number", () => {
  assert.equal(parseSeed(" "), undefined);
  assert.equal(parseSeed("0"), 0);
  assert.equal(parseSeed(" 123 "), 123);
});

test("every server code of POST /games has its own readable German text", () => {
  const e = (status: number, code: string, message = "english server text") => errorText(new ApiError(status, code, message));
  assert.match(e(422, "unknown_player", "no registered player found for seat 3"), /Platz 3/);
  assert.equal(e(422, "unknown_player", "x"), txt("lobby.err_unknown_player_any").de);
  assert.equal(e(429, "rate_limited"), txt("lobby.err_rate_limited").de);
  assert.equal(e(422, "invalid_seats"), txt("lobby.err_invalid_seats").de);
  assert.equal(e(422, "game_limit"), txt("lobby.err_game_limit").de);
  assert.equal(e(401, "login_required"), txt("lobby.err_login_required").de);
  assert.equal(e(0, "network"), txt("lobby.err_network").de);
  for (const code of ["unknown_player", "rate_limited", "invalid_seats", "game_limit", "login_required"]) {
    assert.ok(!e(422, code, "english server text").includes("english"), code);
  }
  assert.match(e(500, "internal_error", "boom"), /boom/);
  assert.match(errorText(new Error("odd")), /odd/);
});
