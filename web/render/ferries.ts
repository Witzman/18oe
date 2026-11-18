// Ferries on the map (#452). A ferry is a blue line over open water between two ports with a distance of 0 or 1 (§11.3.7,
// map.jpg: a blue line with the distance in an oval). The engine knows them as blue paths in the sea hexes; /map does
// not export a path colour, so the lines are found the way the engine builds its ferry components: from every ferry end
// of `ports` (a land hex and its side), through the sea hex across that side and on along the paths, from path to path
// over shared nodes and over hex sides, as long as the paths lie in sea hexes. Pure geometry, no PixiJS.
import type { MapHex, PortEntry } from "./mapdata.ts";
import type { TilePath } from "./track-axes.ts";

/** A ferry: its paths (`hex#index` into the hex's `paths`), the land ends and the number in the oval. */
export interface Ferry {
  /** Keys `${hexId}#${pathIndex}` of the blue paths. */
  paths: string[];
  /** The ferry ends: land hex and side (number, or "offshore" for a port in the sea). */
  ends: { hex: string; edge: number | string }[];
  distance: number;
  /** The path that carries the oval: the middle one of the line. */
  label: string;
}

const key = (hex: string, i: number): string => `${hex}#${i}`;
const opposite = (side: number): number => (side + 3) % 6;
const edgesOf = (p: TilePath): number[] => [p.a, p.b].flatMap((e) => ("edge" in e ? [e.edge] : []));
const nodeOf = (p: TilePath): number[] => [p.a, p.b].flatMap((e) => ("node" in e ? [e.node] : []));

/** The ferries of the map: one per group of blue paths that a ferry end of `ports` reaches. */
export function findFerries(hexes: readonly MapHex[], ports: readonly PortEntry[] | undefined): Ferry[] {
  const byId = new Map(hexes.map((h) => [h.id, h]));
  const seen = new Set<string>();
  const out: Ferry[] = [];
  for (const entry of ports ?? []) {
    if (!entry.ferries?.length || typeof entry.edge !== "number") continue;
    const land = byId.get(entry.hex);
    const sea = land?.neighbors[entry.edge] ? byId.get(land.neighbors[entry.edge]!) : undefined;
    if (!sea || sea.kind !== "sea") continue;
    const starts = (sea.paths ?? []).map((p, i) => [p, i] as const).filter(([p]) => edgesOf(p).includes(opposite(entry.edge as number)));
    for (const [, i] of starts) {
      if (seen.has(key(sea.id, i))) continue;
      const line = collect(byId, sea.id, i);
      line.forEach((k) => seen.add(k));
      out.push({ paths: line, ends: [], distance: entry.ferries[0]!.distance, label: line[Math.floor(line.length / 2)]! });
    }
  }
  // the ends of each ferry: the `ports` entries whose side leads into the line, and an offshore port that names one of them
  for (const ferry of out) {
    const lineHexes = new Set(ferry.paths.map((k) => k.split("#")[0]!));
    const leadsIn = (entry: PortEntry) => {
      const nid = typeof entry.edge === "number" ? byId.get(entry.hex)?.neighbors[entry.edge] : undefined;
      return !!nid && lineHexes.has(nid);
    };
    const near = (ports ?? []).filter((e) => e.ferries?.length && leadsIn(e));
    for (const entry of ports ?? []) {
      if (!entry.ferries?.length) continue;
      const names = entry.ferries.some((f) => near.some((n) => n.hex === f.hex && n.edge === f.exit));
      if (near.includes(entry) || (entry.edge === "offshore" && names)) ferry.ends.push({ hex: entry.hex, edge: entry.edge });
    }
  }
  return out;
}

/** The paths joined to the start path: in a hex over shared nodes, over a hex side into the neighbour's matching side. */
function collect(byId: ReadonlyMap<string, MapHex>, hexId: string, index: number): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  const queue: [string, number][] = [[hexId, index]];
  while (queue.length) {
    const [id, i] = queue.shift()!;
    const k = key(id, i);
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(k);
    const hex = byId.get(id)!;
    const path = hex.paths![i]!;
    // in a sea hex all lines are one ferry (as the engine joins them); a stub to a port junction only over its node
    (hex.paths ?? []).forEach((other, j) => {
      if (j !== i && (!other.terminal || nodeOf(path).some((n) => nodeOf(other).includes(n)))) queue.push([id, j]);
    });
    for (const side of edgesOf(path)) {
      const nid = hex.neighbors[side];
      const next = nid ? byId.get(nid) : undefined;
      if (!next || next.kind !== "sea") continue;
      (next.paths ?? []).forEach((other, j) => {
        if (edgesOf(other).includes(opposite(side))) queue.push([next.id, j]);
      });
    }
  }
  return out;
}
