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

// Prüfung der Rücksetzseite (#282). Liefert den Textschlüssel des Fehlers oder null.
export function validateReset(email: string): string | null {
  if (!email.trim()) return "access.err_required";
  return EMAIL_FORM.test(email.trim()) ? null : "access.err_email_form";
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

// Hintergrund des Titelbilds (#280): reine CSS-Animation, rein dekorativ. Stilisierter Zug mit Dampf auf
// Schienen vor Abendhimmel; Farben, Dauer und Takt kommen aus den Theme-Tokens (theme.css). Die Seite
// hängt nicht davon ab: das Formular steht im normalen Fluss darüber. Steht das Theme-Token
// motion.enabled auf 0, bleibt das Bild statisch (data-still); prefers-reduced-motion regelt das CSS.
export function titleStage(): HTMLElement {
  const still = getComputedStyle(document.documentElement).getPropertyValue("--motion-enabled").trim() === "0";
  const puffs = [0, 1, 2, 3].map(() => h("i", { class: "puff" }));
  const wheels = [0, 1, 2].map(() => h("i", { class: "wheel" }));
  const train = h("div", { class: "train" },
    h("div", { class: "loco" }, h("i", { class: "chimney" }), h("div", { class: "steam" }, ...puffs), ...wheels),
    h("div", { class: "car" }), h("div", { class: "car" }));
  const stage = h("div", { class: "title-stage", "aria-hidden": "true" },
    h("i", { class: "sun" }), h("div", { class: "hills" }), train,
    h("div", { class: "track" }, h("i", { class: "rail" }), h("i", { class: "sleepers" })));
  if (still) stage.setAttribute("data-still", "");
  return stage;
}

// Passwort zurücksetzen, nur POC (#282): E-Mail eingeben, das neue Passwort erscheint auf der Seite.
// Ersetzt durch den Ablauf mit Mail-Link (#283).
export function resetPage(api: Api): HTMLElement {
  const error = h("p", { class: "error", role: "alert" });
  const email = h("input", { name: "email", type: "email", autocomplete: "email" });
  const submit = h("button", { type: "submit" }, txt("access.submit_reset").de);
  const result = h("div", { class: "reset-result", hidden: true });
  const onsubmit = async (ev: Event) => {
    ev.preventDefault();
    error.textContent = "";
    const bad = validateReset(email.value);
    if (bad) { error.textContent = txt(bad).de; return; }
    submit.disabled = true;
    try {
      const { password } = await api.resetPassword(email.value.trim());
      const copy = h("button", { type: "button" }, txt("access.reset_copy").de);
      copy.onclick = () => { void navigator.clipboard?.writeText(password).then(() => { copy.textContent = txt("access.reset_copied").de; }); };
      result.replaceChildren(
        h("p", {}, txt("access.reset_done").de),
        h("div", { class: "row" }, h("code", { class: "new-password", "data-testid": "new-password" }, password), copy),
        h("p", { class: "muted" }, txt("access.reset_then").de));
      result.hidden = false;
    } catch (e) {
      error.textContent = errorText(e);
    }
    submit.disabled = false;
  };
  return h("div", { class: "access" },
    titleStage(),
    h("header", { class: "title" }, h("h1", {}, "18OE"), h("p", { class: "game-title" }, txt("access.game_title").de)),
    h("div", { class: "panel" },
      h("h2", {}, txt("access.title_reset").de),
      h("p", { class: "muted" }, txt("access.hint_reset").de),
      h("form", { onsubmit, novalidate: true }, field(txt("access.email_label").de, email), h("div", { class: "row" }, submit), error),
      result,
      h("p", {}, h("a", { href: "#/login" }, txt("access.to_login").de))),
    versionFooter());
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
    titleStage(),
    h("header", { class: "title" }, h("h1", {}, "18OE"), h("p", { class: "game-title" }, txt("access.game_title").de)),
    h("div", { class: "panel" },
      h("h2", {}, txt(reg ? "access.title_register" : "access.title_login").de),
      h("form", { onsubmit, novalidate: true }, ...fields, h("div", { class: "row" }, submit), error),
      h("p", {}, h("a", { href: reg ? "#/login" : "#/register" }, txt(reg ? "access.to_login" : "access.to_register").de)),
      reg ? null : h("p", {}, h("a", { href: "#/reset" }, txt("access.to_reset").de))),
    versionFooter());
}
