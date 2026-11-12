// Which hexes of state.map changed between two polls (ui-spec 2.3: the tiles layer redraws only
// those). Compared per hex: tile name, rotation, colour, token list, builder (laid_by, once #150
// delivers it). A hex that drops out of state.map changed too (back to its printed state).
import type { HexChange } from "../types.ts";

export type TileSignatures = Map<string, string>;

export function signature(c: HexChange): string {
  const laidBy = (c.tile as { laid_by?: unknown }).laid_by ?? null;
  return JSON.stringify([c.tile.name, c.tile.rotation, c.tile.color, c.tokens ?? [], laidBy]);
}

export function signatures(map: readonly HexChange[]): TileSignatures {
  return new Map(map.map((c) => [c.hex, signature(c)]));
}

/** Hex ids whose entry differs between prev and next (added, removed or changed), sorted. */
export function changedHexes(prev: TileSignatures, next: TileSignatures): string[] {
  const out = new Set<string>();
  for (const [hex, sig] of next) if (prev.get(hex) !== sig) out.add(hex);
  for (const hex of prev.keys()) if (!next.has(hex)) out.add(hex);
  return [...out].sort();
}
