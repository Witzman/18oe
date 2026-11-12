import { ApiError, type Api } from "../api.ts";
import type { Account, Game, GameSummary, SeatRequest } from "../types.ts";
import { h } from "./dom.ts";

export interface Ctx {
  api: Api;
  go: (hash: string) => void;
  me: Account | null;
  // Filled at login (the list is only given against the access code); empty after a reload.
  accounts: Account[];
}

const MIN_SEATS = 3;
const MAX_SEATS = 7;

function msg(e: unknown): string {
  return e instanceof ApiError ? e.message : String(e);
}

export function loginPage(ctx: Ctx, done: (me: Account) => void): HTMLElement {
  const error = h("p", { class: "error" });
  const body = h("div");
  const codeInput = h("input", { type: "password", placeholder: "Zugangswort", autocomplete: "off" });
  const step1 = async (e: Event) => {
    e.preventDefault();
    error.textContent = "";
    try {
      const { accounts } = await ctx.api.accounts(codeInput.value);
      ctx.accounts = accounts;
      const select = h("select", {}, ...accounts.map((a) => h("option", { value: a.id }, a.name)));
      const go = async (ev: Event) => {
        ev.preventDefault();
        try {
          done(await ctx.api.login(select.value, codeInput.value));
        } catch (err) {
          error.textContent = msg(err);
        }
      };
      body.replaceChildren(h("form", { onsubmit: go }, h("div", { class: "row" }, select, h("button", { type: "submit" }, "Anmelden"))));
    } catch (err) {
      error.textContent = err instanceof ApiError && err.status === 401 ? "Zugangswort falsch." : msg(err);
    }
  };
  body.append(h("form", { onsubmit: step1 }, h("div", { class: "row" }, codeInput, h("button", { type: "submit" }, "Weiter"))));
  return h("div", {}, h("h1", {}, "18OE"), h("div", { class: "panel" }, body, error));
}

export async function gamesPage(ctx: Ctx): Promise<HTMLElement> {
  const { games } = await ctx.api.listGames();
  return h(
    "div", {},
    h("h1", {}, "18OE"),
    h("div", { class: "row" }, h("span", { class: "muted" }, `Angemeldet als ${ctx.me?.name ?? "?"}`),
      h("button", { onclick: async () => { await ctx.api.logout(); ctx.go("#/login"); } }, "Abmelden")),
    h("h2", {}, "Deine Partien"),
    games.length === 0 ? h("p", { class: "muted" }, "Noch keine Partie.") : gameList(ctx, games),
    h("h2", {}, "Neue Partie"),
    newGameForm(ctx),
  );
}

function gameList(ctx: Ctx, games: GameSummary[]): HTMLElement {
  return h("div", {}, ...games.map((g) =>
    h("div", { class: "row" },
      h("a", { href: `#/game/${g.id}` }, `Partie ${g.id}`),
      h("span", { class: "muted" }, `${g.status}, ${g.seats.length} Plätze, Zug ${g.seq}`))));
}

function newGameForm(ctx: Ctx): HTMLElement {
  const error = h("p", { class: "error" });
  const others = ctx.accounts.filter((a) => a.id !== ctx.me?.id);
  const seatsBox = h("div");
  const count = h("select", {}, ...Array.from({ length: MAX_SEATS - MIN_SEATS + 1 }, (_, i) =>
    h("option", { value: String(MIN_SEATS + i) }, `${MIN_SEATS + i} Spieler`)));
  count.value = "4";
  let selects: HTMLSelectElement[] = [];
  const drawSeats = () => {
    selects = [];
    seatsBox.replaceChildren(h("div", { class: "row" }, `Platz 1: ${ctx.me?.name ?? ""}`));
    for (let i = 1; i < Number(count.value); i++) {
      const s = h("select", {}, h("option", { value: "bot" }, "Bot"), ...others.map((a) => h("option", { value: a.id }, a.name)));
      selects.push(s);
      seatsBox.append(h("div", { class: "row" }, `Platz ${i + 1}:`, s));
    }
  };
  count.addEventListener("change", drawSeats);
  drawSeats();
  const create = async (e: Event) => {
    e.preventDefault();
    error.textContent = "";
    const seats: SeatRequest[] = [{ kind: "human", account_id: ctx.me?.id ?? "" }];
    for (const s of selects) seats.push(s.value === "bot" ? { kind: "bot" } : { kind: "human", account_id: s.value });
    try {
      const game = await ctx.api.createGame(seats);
      ctx.go(`#/game/${game.id}`);
    } catch (err) {
      error.textContent = msg(err);
    }
  };
  return h("form", { onsubmit: create }, h("div", { class: "row" }, count), seatsBox,
    h("button", { type: "submit" }, "Anlegen"), error);
}

// Empty frame of the game page: what the later UI issues (#45 ff.) fill in.
export function gameFrame(): { root: HTMLElement; render: (g: Game) => void } {
  const status = h("div", { class: "panel" });
  const log = h("pre", { class: "panel muted" });
  const root = h("div", {}, h("p", {}, h("a", { href: "#/" }, "← Partien")), h("h1", {}, "18OE"), status, log);
  const render = (g: Game) => {
    const m = g.state.meta;
    const mine = g.state.prompt.viewer_to_act;
    status.replaceChildren(
      h("div", {}, `Partie ${g.id} · ${m.round.type} · Zug ${g.seq} · Phase ${m.phase.name}`),
      h("div", { class: mine ? "turn" : "muted" },
        m.finished ? `Beendet, Sieger: ${m.winner ?? "?"}` : mine ? "Du bist dran" : `Am Zug: ${m.active_players.join(", ")}`),
    );
    log.textContent = g.state.log.map((l) => l.text).join("\n");
  };
  return { root, render };
}
