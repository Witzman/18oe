// Our map and price board in the page's place, as long as they stand for the game the page shows (#627): a game
// that cannot be read, or one of another title, gives the page its own views back.
import type { Board } from "../render/board.ts";
import type { PageGame, Views } from "./page.ts";
import { attachMap, attachMarket, type Placed, type Store } from "./place.ts";

export interface Drawer {
  setBoard(board: Board): void;
}

export interface Deps {
  document: Document;
  storage: Store;
  /** Runs once, before the next paint. */
  frame(run: () => void): void;
  map(stage: HTMLElement, game: PageGame, first: Board): Promise<Drawer>;
  market(stage: HTMLElement): Drawer;
}

export function createViews(deps: Deps): Views & { refresh(): void } {
  // the last board read and its game; null when there is none to show
  let board: Board | null = null;
  // the game the page shows: its engine class gives the fixed map, once, when the map is first drawn
  let shownGame: PageGame = null;
  // why the game cannot be read
  let lost: string | null = null;
  let queued = false;

  let placed: Placed | null = null;
  let map: Drawer | null = null;
  let drawn: Board | null = null;
  let mounting = false;
  let updates = 0;

  let market: Placed | null = null;
  let priceBoard: Drawer | null = null;
  let priced: Board | null = null;

  // for tests and bug reports: how often the map took a new board, and how many hexes it holds
  const note = (shown: Board) => Object.assign(placed!.stage.dataset, { updates: String(++updates), hexes: String(shown.map.length) });

  async function updateMap() {
    placed ??= attachMap(deps.document, deps.storage, schedule);
    placed.lose(lost);
    if (!placed.sync() || !placed.showing() || !board || mounting) return;
    try {
      if (!map) {
        mounting = true;
        const first = board;
        map = await deps.map(placed.stage, shownGame, first);
        drawn = first;
        mounting = false;
        note(first);
        if (board !== drawn) schedule();
      } else if (board !== drawn) {
        map.setBoard(board);
        drawn = board;
        note(board);
      }
    } catch (error) {
      console.warn("18OE map", error);
      placed.fail(String((error as Error)?.message ?? error));
    }
  }

  function updateMarket() {
    market ??= attachMarket(deps.document, deps.storage, schedule);
    market.lose(lost);
    if (!market.sync() || !market.showing() || !board) return;
    try {
      priceBoard ??= deps.market(market.stage);
      if (board !== priced) {
        priceBoard.setBoard(board);
        priced = board;
        // for tests and bug reports, as on the map
        market.stage.dataset.cells = String(board.market!.rows.flat().filter(Boolean).length);
        market.stage.dataset.companies = String(board.market!.rows.flat().reduce((n, c) => n + (c?.corporations.length ?? 0), 0));
      }
    } catch (error) {
      console.warn("18OE market", error);
      market.fail(String((error as Error)?.message ?? error));
    }
  }

  const idle = () => board === null && lost === null;

  async function update() {
    if (idle()) return;
    updateMarket();
    await updateMap();
  }

  function schedule() {
    if (queued) return;
    queued = true;
    deps.frame(() => { queued = false; void update(); });
  }

  return {
    show(next, game) {
      board = next;
      shownGame = game;
      lost = null;
      schedule();
    },
    leave() {
      board = null;
      lost = null;
      placed?.remove();
      market?.remove();
    },
    lose(reason) {
      board = null;
      lost = reason;
      // at once: no frame may show the old state as the current one
      placed?.lose(reason);
      market?.lose(reason);
      schedule();
    },
    /** The page changed its elements. */
    refresh() {
      if (!idle()) schedule();
    },
  };
}
