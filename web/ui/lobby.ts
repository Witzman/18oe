// Lobby nach dem Login (#211): laufende Partien fortsetzen oder eine neue anlegen.
// Die Partie startet sofort (Entscheidung des Eigentümers 2026-11-13, #212): der Ersteller hält
// Platz 1, jeder weitere Platz ist ein Bot oder ein Mensch, den man per Name oder E-Mail benennt
// (kein Konten-Listing, die Auflösung geschieht auf dem Server). Alle Texte stehen in text.ts.
import { ApiError, type Api } from "../api.ts";
import type { Account, GameSummary, SeatRequest } from "../types.ts";
import { h } from "./dom.ts";
import { txt } from "./text.ts";

export const MIN_SEATS = 3;
export const MAX_SEATS = 7;
export const DEFAULT_SEATS = 4;

// Ein Platz im Formular (Platz 1 gehört dem Ersteller und steht nicht hier).
export interface SeatDraft { kind: "bot" | "human"; account: string }

const fill = (key: string, vars: Record<string, string | number>): string =>
  Object.entries(vars).reduce((t, [k, v]) => t.replaceAll(`{${k}}`, String(v)), txt(key).de);

// Prüfung vor dem Senden. Liefert den fertigen Fehlertext oder null. Rein: kein DOM.
// `seats` sind die Plätze 2 und folgende; `me` ist der Ersteller (Platz 1).
export function validateForm(me: Account, seats: SeatDraft[], seed: string): string | null {
  const seen = new Set<string>([me.name.trim().toLowerCase()]);
  for (const [i, s] of seats.entries()) {
    if (s.kind !== "human") continue;
    const who = s.account.trim().toLowerCase();
    if (!who) return fill("lobby.err_seat_empty", { n: i + 2 });
    if (seen.has(who)) return fill("lobby.err_seat_double", { n: i + 2 });
    seen.add(who);
  }
  if (seed.trim() !== "" && !/^\d{1,10}$/.test(seed.trim())) return txt("lobby.err_seed").de;
  return null;
}

// Der Ersteller hält immer Platz 1 (der Server verlangt das), benannt über seine Konto-ID.
export function buildSeats(me: Account, seats: SeatDraft[]): SeatRequest[] {
  return [
    { kind: "human", account_id: me.id },
    ...seats.map((s): SeatRequest => (s.kind === "bot" ? { kind: "bot" } : { kind: "human", account: s.account.trim() })),
  ];
}

export function parseSeed(seed: string): number | undefined {
  return seed.trim() === "" ? undefined : Number(seed.trim());
}

// Server-Fehler -> verständlicher Text je Code. Rein: kein DOM.
export function errorText(err: unknown): string {
  if (!(err instanceof ApiError)) return fill("lobby.err_other", { message: String(err) });
  if (err.status === 0) return txt("lobby.err_network").de;
  switch (err.code) {
    case "unknown_player": {
      const n = /seat (\d+)/.exec(err.message)?.[1];
      return n ? fill("lobby.err_unknown_player", { n }) : txt("lobby.err_unknown_player_any").de;
    }
    case "rate_limited": case "invalid_seats": case "game_limit": case "login_required":
      return txt(`lobby.err_${err.code}`).de;
    default:
      return fill("lobby.err_other", { message: err.message });
  }
}

function statusText(status: string): string {
  const known = txt(`lobby.status_${status}`);
  return known.de === `lobby.status_${status}` ? status : known.de;
}

// Eine Zeile der Liste. Runde und "wer ist dran" liefert GET /games noch nicht (#152/#163).
export function gameRow(g: GameSummary, me: Account | null): HTMLElement {
  const others = g.seats.filter((s) => s.account_id !== me?.id).map((s) => s.name).join(", ");
  return h("li", { class: "game-row" },
    h("a", { class: "game-link", href: `#/game/${g.id}` }, fill("lobby.game_title", { id: g.id })),
    h("span", { class: "muted" }, [statusText(g.status), fill("lobby.game_seq", { seq: g.seq }),
      fill("lobby.game_players", { names: others })].join(" · ")),
    h("a", { class: "game-open", href: `#/game/${g.id}` }, txt("lobby.game_open").de));
}

export function gameList(games: GameSummary[], me: Account | null): HTMLElement {
  if (games.length === 0) return h("p", { class: "muted", "data-empty": "" }, txt("lobby.games_empty").de);
  // Neueste zuerst.
  return h("ul", { class: "game-list" }, ...[...games].sort((a, b) => b.id - a.id).map((g) => gameRow(g, me)));
}

export function newGameForm(api: Api, me: Account, go: (hash: string) => void): HTMLElement {
  const error = h("p", { class: "error", role: "alert" });
  const count = h("select", { name: "count", "aria-label": txt("lobby.seat_count").de },
    ...Array.from({ length: MAX_SEATS - MIN_SEATS + 1 }, (_, i) =>
      h("option", { value: String(MIN_SEATS + i) }, fill("lobby.seat_count_option", { n: MIN_SEATS + i }))));
  count.value = String(DEFAULT_SEATS);
  const seed = h("input", { name: "seed", type: "text", inputmode: "numeric", autocomplete: "off" });
  const submit = h("button", { type: "submit" }, txt("lobby.submit").de);
  const seatsBox = h("div", { class: "seats" });
  // Eingaben überleben ein Ändern der Platzzahl.
  const drafts: SeatDraft[] = Array.from({ length: MAX_SEATS - 1 }, () => ({ kind: "bot", account: "" }));

  const drawSeats = () => {
    const rows = [h("div", { class: "row seat" }, h("strong", {}, fill("lobby.seat_label", { n: 1 })),
      h("span", {}, fill("lobby.seat_you", { name: me.name })))];
    for (let i = 0; i < Number(count.value) - 1; i++) {
      const n = i + 2;
      const draft = drafts[i]!;
      const name = h("input", {
        name: `account${n}`, type: "text", autocomplete: "off", value: draft.account,
        placeholder: txt("lobby.seat_account_placeholder").de, "aria-label": fill("lobby.seat_account", { n }),
      });
      name.hidden = draft.kind === "bot";
      name.addEventListener("input", () => { draft.account = name.value; });
      const kind = h("select", { name: `kind${n}`, "aria-label": fill("lobby.seat_kind", { n }) },
        h("option", { value: "bot" }, txt("lobby.seat_bot").de), h("option", { value: "human" }, txt("lobby.seat_human").de));
      kind.value = draft.kind;
      kind.addEventListener("change", () => {
        draft.kind = kind.value === "human" ? "human" : "bot";
        name.hidden = draft.kind === "bot";
        if (!name.hidden) name.focus();
      });
      rows.push(h("div", { class: "row seat" }, h("strong", {}, fill("lobby.seat_label", { n })), kind, name));
    }
    seatsBox.replaceChildren(...rows);
  };
  count.addEventListener("change", drawSeats);
  drawSeats();

  const onsubmit = async (ev: Event) => {
    ev.preventDefault();
    error.textContent = "";
    const seats = drafts.slice(0, Number(count.value) - 1);
    const bad = validateForm(me, seats, seed.value);
    if (bad) { error.textContent = bad; return; }
    submit.disabled = true;
    submit.textContent = txt("lobby.submitting").de;
    try {
      const game = await api.createGame(buildSeats(me, seats), parseSeed(seed.value));
      go(`#/game/${game.id}`);
    } catch (e) {
      error.textContent = errorText(e);
      submit.disabled = false;
      submit.textContent = txt("lobby.submit").de;
    }
  };

  return h("form", { class: "new-game", onsubmit, novalidate: true },
    h("p", { class: "muted" }, txt("lobby.new_intro").de),
    h("label", { class: "row" }, h("span", {}, txt("lobby.seat_count").de), count),
    seatsBox,
    h("label", { class: "field" }, h("span", {}, txt("lobby.seed_label").de), seed, h("small", { class: "muted" }, txt("lobby.seed_hint").de)),
    h("div", { class: "row" }, submit), error);
}

export interface LobbyCtx { api: Api; go: (hash: string) => void; me: Account | null }

export async function lobbyPage(ctx: LobbyCtx): Promise<HTMLElement> {
  const me = ctx.me;
  let list: HTMLElement;
  try {
    list = gameList((await ctx.api.listGames()).games, me);
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) throw e; // main.ts leitet auf die Anmeldung
    list = h("p", { class: "error" }, fill("lobby.err_list", { message: e instanceof ApiError ? e.message : String(e) }));
  }
  return h("div", { class: "lobby" },
    h("h1", {}, "18OE"),
    h("div", { class: "row" }, h("span", { class: "muted" }, fill("lobby.signed_in", { name: me?.name ?? "?" })),
      h("button", { type: "button", onclick: async () => { await ctx.api.logout(); ctx.go("#/login"); } }, txt("lobby.logout").de)),
    h("h2", {}, txt("lobby.games_title").de),
    list,
    h("h2", {}, txt("lobby.new_title").de),
    me ? newGameForm(ctx.api, me, ctx.go) : null);
}
