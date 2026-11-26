// What the map reads of a game state (map.ts: state.map, state.corporations, state.meta), for a caller that has no
// server view: the browser add-on reads these three from the page of the game (#613).
import { hexToNumber } from "../themes/color.ts";
import type { GameState, HexChange } from "../types.ts";

export interface BoardCompany {
  id: string;
  /** Full name, for the price board's tooltips and lists (#619). */
  name?: string;
  closed: boolean;
  tokens: { used: boolean; hex: string | null }[];
  /** The engine's colours of the company ("#rrggbb", "black" or "white"), for badges as on 18xx.games (#618). */
  color?: string;
  text_color?: string;
}

/** A flat company token in the company's own colours, as 18xx.games draws it. */
export interface Badge {
  color: number;
  ink: number;
}

const NAMED: Record<string, number> = { black: 0x000000, white: 0xffffff };

function colour(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const named = NAMED[value.toLowerCase()];
  if (named !== undefined) return named;
  return /^#[0-9a-f]{6}$/i.test(value) ? hexToNumber(value) : undefined;
}

/** Undefined without a usable colour: the map then draws the theme's token. */
export function badgeOf(companies: readonly BoardCompany[], id: string): Badge | undefined {
  const company = companies.find((c) => c.id === id);
  const color = colour(company?.color);
  return color === undefined ? undefined : { color, ink: colour(company?.text_color) ?? 0xffffff };
}

export interface Board {
  /** Hexes with a laid tile, tokens or a patronage marker, as GameState.map. */
  map: HexChange[];
  /** In the game's order: the fallback token colours go by position. */
  corporations: BoardCompany[];
  /** Tile colours of the current phase (the revenue shown on the tiles). */
  phase_tiles: string[];
  /** The stock market, as GameState.market (the price board, #619). */
  market?: GameState["market"];
}

export function boardState(board: Board): GameState {
  for (const field of ["map", "corporations", "phase_tiles"] as const) {
    if (!Array.isArray(board[field])) throw new Error(`board: ${field} is missing`);
  }
  return {
    map: board.map,
    corporations: board.corporations,
    meta: { phase: { tiles: board.phase_tiles }, current: null },
  } as unknown as GameState;
}
