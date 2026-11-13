import assert from "node:assert/strict";
import { test } from "node:test";
import { ApiError } from "../api.ts";
import { errorText, validate } from "../ui/access.ts";
import { txt } from "../ui/text.ts";

const ok = { name: "Anna", email: "anna@example.de", password: "geheim123", code: "einlass" };

test("register validation: empty fields, e-mail form, short password", () => {
  assert.equal(validate("register", ok), null);
  assert.equal(validate("register", { ...ok, name: " " }), "access.err_required");
  assert.equal(validate("register", { ...ok, code: "" }), "access.err_required");
  assert.equal(validate("register", { ...ok, email: "anna" }), "access.err_email_form");
  assert.equal(validate("register", { ...ok, password: "kurz" }), "access.err_password_short");
});

test("login validation: both fields needed", () => {
  assert.equal(validate("login", { login: "Anna", password: "x" }), null);
  assert.equal(validate("login", { login: "", password: "x" }), "access.err_required");
  assert.equal(validate("login", { login: "Anna", password: "" }), "access.err_required");
});

test("every server code of /register and /login has its own readable text", () => {
  const cases: [number, string][] = [
    [401, "invalid_login"], [429, "rate_limited"], [403, "invalid_invite"], [422, "invalid_name"],
    [422, "invalid_email"], [422, "invalid_password"], [409, "name_taken"], [409, "registration_failed"],
  ];
  const seen = new Set<string>();
  for (const [status, code] of cases) {
    const text = errorText(new ApiError(status, code, "english server text"));
    assert.equal(text, txt(`access.err_${code}`).de);
    assert.ok(!text.includes("english server text"), code);
    seen.add(text);
  }
  assert.equal(seen.size, cases.length);
});

test("network and unknown errors fall back to a generic text", () => {
  assert.equal(errorText(new ApiError(0, "network", "x")), txt("access.err_network").de);
  assert.match(errorText(new ApiError(500, "internal_error", "boom")), /boom/);
  assert.match(errorText(new Error("odd")), /odd/);
});
