// The parts of GET /map (#43, lib/oe/map_data.rb) the map renderer reads, and the
// height of a hex (ui-spec 2.4). World coordinates x/y come from the server
// (Oe::MapData.world is the only coordinate conversion); nothing here recomputes them.
import type { Theme } from "../themes/schema.ts";

export type HexKind = "land" | "sea" | "offboard";

export interface MapHex {
  id: string;
  /** Flat world position of the centre, side length 1, y down. */
  x: number;
  y: number;
  kind: HexKind;
  sea_zone?: string;
  terrain?: { types: string[]; cost: number }[];
  /** Geometric neighbour per edge 0..5 (null at the map border). */
  neighbors: (string | null)[];
}

export interface MapLayout {
  orientation: string;
  /** Centre-to-neighbour vector per edge 0..5 (edge i points to neighbors[i]). */
  edge_vectors: [number, number][];
}

export interface MapGeometry {
  layout: MapLayout;
  hexes: MapHex[];
}

type Heights = Pick<Theme["camera"], "heightLand" | "heightHill" | "heightMountain" | "heightTile">;

/**
 * Height of a hex top in side lengths (ui-spec 2.4): sea and off-boards in a sea
 * zone 0, land heightLand (+ hill / mountain), plus heightTile when a tile lies on it.
 * Assumption (not in the spec): an off-board hex outside a sea zone stands at
 * heightLand, like land.
 */
export function hexHeight(hex: MapHex, camera: Heights, tiled = false): number {
  if (hex.kind === "sea" || (hex.kind === "offboard" && hex.sea_zone)) return 0;
  const types = new Set((hex.terrain ?? []).flatMap((t) => t.types));
  let z = camera.heightLand;
  if (types.has("mountain")) z += camera.heightMountain;
  else if (types.has("hill")) z += camera.heightHill;
  return tiled ? z + camera.heightTile : z;
}
