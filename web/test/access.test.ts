import assert from "node:assert/strict";
import { test } from "node:test";
import { ApiError } from "../api.ts";
import { errorText, validate, validateReset } from "../ui/access.ts";
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
    [422, "unknown_email"],
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

test("title screen (#280): game title text exists, the scene styles use theme tokens only", async () => {
  const { readFileSync } = await import("node:fs");
  assert.equal(txt("access.game_title").de, "On the Rails of the Orient Express");
  const css = readFileSync(new URL("../theme.css", import.meta.url), "utf8");
  const section = css.slice(css.indexOf("/* Title and login screen (issue 280)"), css.indexOf("/* Lobby, issue 211"));
  assert.ok(section.includes(".title-stage"));
  assert.ok(section.includes("prefers-reduced-motion: reduce"));
  assert.deepEqual(section.replace(/\/\*[^]*?\*\//g, "").match(/#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(/g) ?? [], [], "no literal colours");
  assert.ok(section.includes("--motion-run-ms-per-hex"), "duration comes from the theme");
});

test("reset validation (#282): e-mail required and well-formed", () => {
  assert.equal(validateReset("anna@example.de"), null);
  assert.equal(validateReset(" "), "access.err_required");
  assert.equal(validateReset("anna"), "access.err_email_form");
});
