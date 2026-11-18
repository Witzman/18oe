// Ports on the map (#451): the public (blue anchor) and private (pink anchor) ports of `ports` in /map as marks, one per
// entry that names a kind. A mark sits on the hex side the entry names or, for an offshore port, in its sea hex. Ferry
// ends and dead ends without a kind are not ports; an unknown kind is ignored.
import type { PortEntry } from "./mapdata.ts";

export type PortKind = "public" | "private";

export interface PortMark { hex: string; side: number | "offshore"; kind: PortKind }

const KINDS: readonly string[] = ["public", "private"];

export function portMarks(ports: readonly PortEntry[] | undefined): PortMark[] {
  const out: PortMark[] = [];
  for (const p of ports ?? []) {
    if (!p.port || !KINDS.includes(p.port)) continue;
    out.push({ hex: p.hex, side: p.edge === "offshore" ? "offshore" : Number(p.edge), kind: p.port as PortKind });
  }
  return out;
}

/**
 * The side whose corner with `side` holds the mark (#459): a mark sits at a corner of its hex side, between the possible
 * tracks (which run through the side middles), on the corner whose other hex is water. With both or neither corner at
 * water, the corner to the higher side (ASSUMPTION: no rule, only a stable choice).
 */
export function portCornerSide(side: number, kindOf: (side: number) => string | undefined): number {
  const prev = (side + 5) % 6, next = (side + 1) % 6;
  return kindOf(prev) === "sea" && kindOf(next) !== "sea" ? prev : next;
}
