import type { Api } from "../api.ts";
import type { Account } from "../types.ts";
import { createGameFrame, type GameFrame } from "./frame/frame.ts";
import { h } from "./dom.ts";
import { lobbyPage } from "./lobby.ts";
import { mountMapView } from "./frame/mapview.ts";
import { mountAuction } from "./panels/auction.ts";
import { mountStock } from "./panels/stock.ts";
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

export function gameFrame(retryNow: () => void = () => {}, api?: Api): GameFrame {
  const frame = createGameFrame(retryNow);
  mountAuction(frame);
  if (api) frame.onDispose(mountMapView(frame, api));
  mountStock(frame);
  return frame;
}
