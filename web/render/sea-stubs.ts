// Port stubs in sea hexes (#444). A sea hex that holds an offshore port or a port arrow carries a short track, a
// "stub": a terminal path from a hex side to a junction in the middle (`junction; path=a:E,b:_0,terminal:1`, the
// engine's map data as 18xx.games has it). Drawn as the data has it, some of these start on a side that faces open
// water, so the stub looks as if it came from a neighbouring sea field (the hex above Amsterdam, K36: the data says
// side 2, the only land neighbour, Amsterdam, lies on side 5).
//
// Rule of the owner (2026-11-18, #444): a stub starts at a side that borders a land hex and ends as an arrow in the
// middle of the sea hex. `landSideStubs` moves the start of a stub whose side faces open water to a side that
// borders land; every other stub stays as the data has it. Display only: the engine's map data (upstream shape,
// rule 11) is not touched and nothing else reads these paths for rules.
//
// Which land side: first the side of a land neighbour that holds offshore docks (Amsterdam L37, København I50: the
// port the sea hex belongs to); else, ASSUMPTION (the data only names the port, not its side), the land side nearest
// to the side the data has, the lower side number on a tie. No land side at all (E20): unchanged.
import type { MapHex } from "./mapdata.ts";
import type { PathEnd } from "./track-axes.ts";

const SIDES = 6;
const DOCKS = "offshore_docks";

const isEdge = (e: PathEnd): e is { edge: number } => "edge" in e;

/** Steps around the hex between two sides (0..3). */
export const sideDistance = (a: number, b: number): number => {
  const d = Math.abs(a - b) % SIDES;
  return Math.min(d, SIDES - d);
};

/**
 * True when the neighbour on the side is sea and carries no line through it. A ferry line (G30 towards G32) is a
 * path from side to side; a port hex next door (G48 beside H49) holds only stubs to its junction, and open water
 * holds nothing: both are water the stub must not start from.
 */
function facesOpenWater(hex: MapHex, side: number, byId: ReadonlyMap<string, MapHex>): boolean {
  const id = hex.neighbors[side];
  const other = id ? byId.get(id) : undefined;
  if (!other) return false;
  return other.kind === "sea" && !other.paths?.some((p) => !p.terminal);
}

const isLand = (other: MapHex | undefined): boolean => !!other && other.kind !== "sea";

const hasDocks = (other: MapHex | undefined): boolean => !!other?.icons?.some((i) => i.name === DOCKS || i.image.includes(DOCKS));

/** The side a stub that faces open water moves to; `current` if there is no land side. */
export function landSide(hex: MapHex, current: number, byId: ReadonlyMap<string, MapHex>): number {
  const sides = [...Array(SIDES).keys()].filter((s) => {
    const id = hex.neighbors[s];
    return id && isLand(byId.get(id));
  });
  if (!sides.length) return current;
  const docks = sides.filter((s) => hasDocks(byId.get(hex.neighbors[s]!)));
  const pool = docks.length ? docks : sides;
  return pool.reduce((best, s) => (sideDistance(s, current) < sideDistance(best, current) ? s : best), pool[0]!);
}

/** The hex with every stub that faces open water moved to a land side; the hex itself when nothing moves. */
export function landSideStub(hex: MapHex, byId: ReadonlyMap<string, MapHex>): MapHex {
  if (hex.kind !== "sea" || hex.junction === undefined || !hex.paths?.length) return hex;
  let moved = false;
  const paths = hex.paths.map((p) => {
    if (!p.terminal) return p;
    const [edgeEnd, nodeEnd] = isEdge(p.a) ? [p.a, p.b] : [p.b, p.a];
    if (!isEdge(edgeEnd) || isEdge(nodeEnd) || !facesOpenWater(hex, edgeEnd.edge, byId)) return p;
    const to = landSide(hex, edgeEnd.edge, byId);
    if (to === edgeEnd.edge) return p;
    moved = true;
    return { ...p, a: isEdge(p.a) ? { edge: to } : p.a, b: isEdge(p.b) ? { edge: to } : p.b };
  });
  if (!moved) return hex;
  // two stubs may end on the same side: keep one
  const seen = new Set<string>();
  const unique = paths.filter((p) => {
    const key = JSON.stringify([p.a, p.b, !!p.terminal]);
    return seen.has(key) ? false : (seen.add(key), true);
  });
  return { ...hex, paths: unique };
}

/** All hexes, the sea hexes with a stub moved to a land side where the data has it facing open water. */
export function landSideStubs(hexes: readonly MapHex[]): MapHex[] {
  const byId = new Map(hexes.map((h) => [h.id, h]));
  return hexes.map((h) => landSideStub(h, byId));
}
