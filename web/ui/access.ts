// Zugang (#210): Anmelden und Registrieren. Alle deutschen Texte stehen in text.ts.
// Die Seiten kennen nur die API und einen Rückruf `done(me)`; wohin es danach geht
// (Partieliste oder die zuvor gewollte Seite nach einem 401, #162), entscheidet main.ts.
import { ApiError, type Api } from "../api.ts";
import type { Account } from "../types.ts";
import { h } from "./dom.ts";
import { SLIDES, nextSlide } from "./title-slides.ts";
import { txt } from "./text.ts";
import { versionFooter } from "./version.ts";

// How long the success message stays before the lobby opens.
export const SUCCESS_MS = 900;

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
  if (!(err instanceof ApiError)) return txt("access.err_other").text.replace("{message}", String(err));
  if (err.status === 0) return txt("access.err_network").text;
  const known = txt(`access.err_${err.code}`);
  if (known.text !== `access.err_${err.code}`) return known.text;
  return txt("access.err_other").text.replace("{message}", err.message);
}

function field(label: string, input: HTMLInputElement, hint?: string): HTMLElement {
  return h("label", { class: "field" }, h("span", {}, label), input, hint ? h("small", { class: "muted" }, hint) : null);
}

// Hintergrund des Titelbilds (#460, ersetzt die Zug-Animation aus #280): ein Slider durch Screenshots der laufenden
// Oberfläche (ui/title-slides.ts), alle motion.titleSlideMs mit Überblenden (motion.titleFadeMs). Punkte unter dem Bild
// wählen ein Bild (Ziele >= 44 px); der Wechsel pausiert, solange die Maus über dem Bild steht oder es berührt wird. Bei
// prefers-reduced-motion und motion.enabled = 0 gibt es keinen Automatik-Wechsel, die Punkte bleiben. Die Seite hängt
// nicht davon ab: das Formular steht im normalen Fluss darüber.
export function titleStage(): HTMLElement {
  const root = getComputedStyle(document.documentElement);
  const num = (name: string, fallback: number) => { const v = Number.parseFloat(root.getPropertyValue(name)); return Number.isFinite(v) ? v : fallback; };
  const still = root.getPropertyValue("--motion-enabled").trim() === "0" || (typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches);
  const every = num("--motion-title-slide-ms", 8000);
  const images = SLIDES.map((s, i) => h("img", { class: "title-slide", src: `title/${s.scene}.png`, alt: "", width: "1747", height: "923", loading: i === 0 ? "eager" : "lazy", draggable: "false" }));
  const dots = SLIDES.map((s, i) => h("button", { type: "button", class: "title-dot", "aria-label": txt(s.alt).text }, h("i", {})));
  const slides = h("div", { class: "title-slides", "aria-hidden": "true" }, ...images);
  const stage = h("div", { class: "title-stage" }, slides, h("nav", { class: "title-dots", "aria-label": txt("access.slides_nav").text }, ...dots));
  let at = 0, hover = false, pressed = false, timer = 0;
  const show = (i: number) => {
    at = i;
    images.forEach((img, k) => img.toggleAttribute("data-active", k === i));
    dots.forEach((d, k) => d.toggleAttribute("aria-current", k === i));
  };
  const restart = () => {
    clearInterval(timer);
    if (still) return;
    timer = window.setInterval(() => {
      if (!stage.isConnected) { clearInterval(timer); return; }
      if (!hover && !pressed) show(nextSlide(at, SLIDES.length));
    }, every);
  };
  dots.forEach((d, k) => { d.onclick = () => { show(k); restart(); }; });
  slides.addEventListener("pointerenter", (e) => { hover = e.pointerType === "mouse"; });
  slides.addEventListener("pointerleave", () => { hover = false; });
  slides.addEventListener("pointerdown", () => { pressed = true; });
  for (const end of ["pointerup", "pointercancel"]) slides.addEventListener(end, () => { pressed = false; });
  if (still) stage.setAttribute("data-still", "");
  show(0);
  restart();
  return stage;
}

// Passwort zurücksetzen, nur POC (#282): E-Mail eingeben, das neue Passwort erscheint auf der Seite.
// Ersetzt durch den Ablauf mit Mail-Link (#283).
export function resetPage(api: Api): HTMLElement {
  const error = h("p", { class: "error", role: "alert" });
  const email = h("input", { name: "email", type: "email", autocomplete: "email" });
  const submit = h("button", { type: "submit" }, txt("access.submit_reset").text);
  const result = h("div", { class: "reset-result", hidden: true });
  const onsubmit = async (ev: Event) => {
    ev.preventDefault();
    error.textContent = "";
    const bad = validateReset(email.value);
    if (bad) { error.textContent = txt(bad).text; return; }
    submit.disabled = true;
    try {
      const { password } = await api.resetPassword(email.value.trim());
      const copy = h("button", { type: "button" }, txt("access.reset_copy").text);
      copy.onclick = () => { void navigator.clipboard?.writeText(password).then(() => { copy.textContent = txt("access.reset_copied").text; }); };
      result.replaceChildren(
        h("p", {}, txt("access.reset_done").text),
        h("div", { class: "row" }, h("code", { class: "new-password", "data-testid": "new-password" }, password), copy),
        h("p", { class: "muted" }, txt("access.reset_then").text));
      result.hidden = false;
    } catch (e) {
      error.textContent = errorText(e);
    }
    submit.disabled = false;
  };
  return h("div", { class: "access" },
    titleStage(),
    h("header", { class: "title" }, h("h1", {}, "18OE"), h("p", { class: "game-title" }, txt("access.game_title").text)),
    h("div", { class: "panel" },
      h("h2", {}, txt("access.title_reset").text),
      h("p", { class: "muted" }, txt("access.hint_reset").text),
      h("form", { onsubmit, novalidate: true }, field(txt("access.email_label").text, email), h("div", { class: "row" }, submit), error),
      result,
      h("p", {}, h("a", { href: "#/login" }, txt("access.to_login").text))),
    versionFooter());
}

// Anmelden (#462): auf der Titelseite steht nur der Slider mit einem Knopf "Login" oben rechts; das Formular liegt in einem
// Dialog (natives <dialog>: Escape, Fokus hinein und zurück). `open` öffnet ihn gleich (abgelaufene Sitzung, 401).
// Registrieren (#/register) zeigt das Formular wie bisher auf der Seite.
export function accessPage(api: Api, mode: AccessMode, done: (me: Account) => void, open = false): HTMLElement {
  const reg = mode === "register";
  const error = h("p", { class: "error", role: "alert" });
  // Status line (#286): shows which step runs or succeeded, so a failure is never silent.
  const status = h("p", { class: "status", role: "status" });
  const input = (name: string, type: string, auto: string) => h("input", { name, type, autocomplete: auto });
  const login = input("login", "text", "username");
  const name = input("name", "text", "username");
  const email = input("email", "email", "email");
  const password = input("password", "password", reg ? "new-password" : "current-password");
  const code = input("code", "password", "off");
  const submit = h("button", { type: "submit" }, txt(reg ? "access.submit_register" : "access.submit_login").text);

  const onsubmit = async (ev: Event) => {
    ev.preventDefault();
    error.textContent = "";
    status.textContent = "";
    const bad = validate(mode, {
      login: login.value, name: name.value, email: email.value, password: password.value, code: code.value,
    });
    if (bad) { error.textContent = txt(bad).text; return; }
    submit.disabled = true;
    status.textContent = txt(reg ? "access.busy_register" : "access.busy_login").text;
    let me: Account;
    try {
      me = reg
        ? await api.register({ name: name.value.trim(), email: email.value.trim(), password: password.value, code: code.value.trim() })
        : await api.login(login.value.trim(), password.value);
      if (!me || typeof me.id !== "string" || typeof me.name !== "string") throw new Error("unexpected response: " + JSON.stringify(me));
    } catch (e) {
      status.textContent = "";
      // A 200 without JSON (#294: api.ts reports it as bad_response) is the same "unexpected answer".
      const unexpected = (e instanceof ApiError && e.code === "bad_response") || (e instanceof Error && e.message.startsWith("unexpected response"));
      error.textContent = unexpected ? txt("access.err_unexpected").text : errorText(e);
      submit.disabled = false;
      return;
    }
    status.textContent = txt(reg ? "access.ok_register" : "access.ok_login").text.replace("{name}", me.name);
    setTimeout(() => {
      try { done(me); } catch (e) {
        status.textContent = "";
        error.textContent = errorText(e);
        submit.disabled = false;
      }
    }, SUCCESS_MS);
  };

  const fields = reg
    ? [field(txt("access.name_label").text, name, txt("access.hint_name").text),
       field(txt("access.email_label").text, email),
       field(txt("access.password_label").text, password, txt("access.hint_password").text),
       field(txt("access.code_label").text, code, txt("access.hint_code").text)]
    : [field(txt("access.login_label").text, login), field(txt("access.password_label").text, password)];

  const panel = h("div", { class: "panel" },
    h("h2", {}, txt(reg ? "access.title_register" : "access.title_login").text),
    h("form", { onsubmit, novalidate: true }, ...fields, h("div", { class: "row" }, submit), status, error),
    h("p", {}, h("a", { href: reg ? "#/login" : "#/register" }, txt(reg ? "access.to_login" : "access.to_register").text)),
    reg ? null : h("p", {}, h("a", { href: "#/reset" }, txt("access.to_reset").text)));
  let bar: HTMLElement | null = null;
  let body: HTMLElement = panel;
  if (!reg) {
    const dialog = h("dialog", { class: "login-dialog", "aria-label": txt("access.title_login").text }) as HTMLDialogElement;
    const close = h("button", { type: "button", class: "login-close" }, txt("access.dialog_close").text);
    const show = () => { if (typeof dialog.showModal === "function" && !dialog.open) dialog.showModal(); else dialog.setAttribute("open", ""); };
    close.onclick = () => dialog.close();
    dialog.addEventListener("click", (ev) => { if (ev.target === dialog) dialog.close(); }); // Tipp neben das Formular
    dialog.append(panel, h("div", { class: "row" }, close));
    const opener = h("button", { type: "button", class: "login-open" }, txt("access.open_login").text);
    opener.onclick = show;
    bar = h("div", { class: "title-bar" }, opener);
    body = dialog;
    if (open) queueMicrotask(() => { if (dialog.isConnected) show(); });
  }
  return h("div", { class: "access" },
    titleStage(),
    bar,
    h("header", { class: "title" }, h("h1", {}, "18OE"), h("p", { class: "game-title" }, txt("access.game_title").text)),
    body,
    versionFooter());
}
