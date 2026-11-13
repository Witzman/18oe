// Zugang (#210): Anmelden und Registrieren. Alle deutschen Texte stehen in text.ts.
// Die Seiten kennen nur die API und einen Rückruf `done(me)`; wohin es danach geht
// (Partieliste oder die zuvor gewollte Seite nach einem 401, #162), entscheidet main.ts.
import { ApiError, type Api } from "../api.ts";
import type { Account } from "../types.ts";
import { h } from "./dom.ts";
import { txt } from "./text.ts";
import { versionFooter } from "./version.ts";

export type AccessMode = "login" | "register";

export const MIN_PASSWORD = 8; // wie lib/oe/accounts.rb (PASSWORD_RANGE)
const EMAIL_FORM = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export interface Fields { login?: string; name?: string; email?: string; password?: string; code?: string }

// Prüfung vor dem Senden. Liefert den Textschlüssel des Fehlers oder null.
export function validate(mode: AccessMode, f: Fields): string | null {
  if (mode === "login") return f.login?.trim() && f.password ? null : "access.err_required";
  if (!f.name?.trim() || !f.email?.trim() || !f.password || !f.code?.trim()) return "access.err_required";
  if (!EMAIL_FORM.test(f.email.trim())) return "access.err_email_form";
  if (f.password.length < MIN_PASSWORD) return "access.err_password_short";
  return null;
}

// Server-Fehler -> verständlicher Text. Rein: kein DOM.
export function errorText(err: unknown): string {
  if (!(err instanceof ApiError)) return txt("access.err_other").de.replace("{message}", String(err));
  if (err.status === 0) return txt("access.err_network").de;
  const known = txt(`access.err_${err.code}`);
  if (known.de !== `access.err_${err.code}`) return known.de;
  return txt("access.err_other").de.replace("{message}", err.message);
}

function field(label: string, input: HTMLInputElement, hint?: string): HTMLElement {
  return h("label", { class: "field" }, h("span", {}, label), input, hint ? h("small", { class: "muted" }, hint) : null);
}

export function accessPage(api: Api, mode: AccessMode, done: (me: Account) => void): HTMLElement {
  const reg = mode === "register";
  const error = h("p", { class: "error", role: "alert" });
  const input = (name: string, type: string, auto: string) => h("input", { name, type, autocomplete: auto });
  const login = input("login", "text", "username");
  const name = input("name", "text", "username");
  const email = input("email", "email", "email");
  const password = input("password", "password", reg ? "new-password" : "current-password");
  const code = input("code", "password", "off");
  const submit = h("button", { type: "submit" }, txt(reg ? "access.submit_register" : "access.submit_login").de);

  const onsubmit = async (ev: Event) => {
    ev.preventDefault();
    error.textContent = "";
    const bad = validate(mode, {
      login: login.value, name: name.value, email: email.value, password: password.value, code: code.value,
    });
    if (bad) { error.textContent = txt(bad).de; return; }
    submit.disabled = true;
    try {
      const me = reg
        ? await api.register({ name: name.value.trim(), email: email.value.trim(), password: password.value, code: code.value.trim() })
        : await api.login(login.value.trim(), password.value);
      done(me);
    } catch (e) {
      error.textContent = errorText(e);
      submit.disabled = false;
    }
  };

  const fields = reg
    ? [field(txt("access.name_label").de, name, txt("access.hint_name").de),
       field(txt("access.email_label").de, email),
       field(txt("access.password_label").de, password, txt("access.hint_password").de),
       field(txt("access.code_label").de, code, txt("access.hint_code").de)]
    : [field(txt("access.login_label").de, login), field(txt("access.password_label").de, password)];

  return h("div", { class: "access" },
    h("h1", {}, "18OE"),
    h("div", { class: "panel" },
      h("h2", {}, txt(reg ? "access.title_register" : "access.title_login").de),
      h("form", { onsubmit, novalidate: true }, ...fields, h("div", { class: "row" }, submit), error),
      h("p", {}, h("a", { href: reg ? "#/login" : "#/register" }, txt(reg ? "access.to_login" : "access.to_register").de))),
    versionFooter());
}
