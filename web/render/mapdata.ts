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
  /** Zero-based row (A = 0) and column number; used to group hexes into blocks (#44). */
  row?: number;
  col?: number;
  /** Colour of the printed tile (white, yellow, gray, red, blue). */
  color?: string;
  /** Track-rights zone (Oe::MapData, game.region_for_hex). */
  zone?: string;
  name?: string;
  /** Edge borders; type "province" separates track-rights zones. */
  borders?: { edge: number; type: string; cost?: number }[];
  /** Line inside the hex between two vertices a, b (engine: 0 = bottom vertex, clockwise). */
  partitions?: { a: number; b: number; type: string; length?: number | null }[];
}

export interface MapLayout {
  orientation: string;
  /** Centre-to-neighbour vector per edge 0..5 (edge i points to neighbors[i]). */
  edge_vectors: [number, number][];
}

export interface MapGeometry {
  layout: MapLayout;
  hexes: MapHex[];
  /** Home hex per corporation (used by flyTo(corpId) before a company has tokens). */
  homes?: { corporation: string; type: string; hex: string }[];
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
