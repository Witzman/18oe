import { ApiError, type Api } from "../api.ts";
import type { Account, GameSummary, SeatRequest } from "../types.ts";
import { createGameFrame, type GameFrame } from "./frame/frame.ts";
import { h } from "./dom.ts";
import { txt } from "./text.ts";

export interface Ctx {
  api: Api;
  go: (hash: string) => void;
  me: Account | null;
  // No account list exists any more (#208); until a replacement for picking co-players exists this stays empty.
  accounts: Account[];
}

const MIN_SEATS = 3;
const MAX_SEATS = 7;

function msg(e: unknown): string {
  return e instanceof ApiError ? e.message : String(e);
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

export type { GameFrame } from "./frame/frame.ts";

export function notFoundPage(): HTMLElement {
  return h("div", {}, h("h1", {}, txt("msg.not_found_title").de), h("p", {}, h("a", { href: "#/" }, txt("msg.not_found_link").de)));
}

export function gameFrame(retryNow: () => void = () => {}): GameFrame {
  return createGameFrame(retryNow);
}
