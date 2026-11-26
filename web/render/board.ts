// What the map reads of a game state (map.ts: state.map, state.corporations, state.meta), for a caller that has no
// server view: the browser add-on reads these three from the page of the game (#613).
import type { GameState, HexChange } from "../types.ts";

export interface BoardCompany {
  id: string;
  closed: boolean;
  tokens: { used: boolean; hex: string | null }[];
}

export interface Board {
  /** Hexes with a laid tile, tokens or a patronage marker, as GameState.map. */
  map: HexChange[];
  /** In the game's order: the fallback token colours go by position. */
  corporations: BoardCompany[];
  /** Tile colours of the current phase (the revenue shown on the tiles). */
  phase_tiles: string[];
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
