import type { Api } from "../api.ts";
import type { Account } from "../types.ts";
import { createGameFrame, type GameFrame } from "./frame/frame.ts";
import { h } from "./dom.ts";
import { lobbyPage } from "./lobby.ts";
import { mountAuction } from "./panels/auction.ts";
import { txt } from "./text.ts";

export interface Ctx {
  api: Api;
  go: (hash: string) => void;
  me: Account | null;
}

export function gamesPage(ctx: Ctx): Promise<HTMLElement> {
  return lobbyPage(ctx);
}

export type { GameFrame } from "./frame/frame.ts";

export function notFoundPage(): HTMLElement {
  return h("div", {}, h("h1", {}, txt("msg.not_found_title").de), h("p", {}, h("a", { href: "#/" }, txt("msg.not_found_link").de)));
}

export function gameFrame(retryNow: () => void = () => {}): GameFrame {
  const frame = createGameFrame(retryNow);
  mountAuction(frame);
  return frame;
}
