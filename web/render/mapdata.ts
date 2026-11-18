// The parts of GET /map (#43, lib/oe/map_data.rb) the map renderer reads, and the
// height of a hex (ui-spec 2.4). World coordinates x/y come from the server
// (Oe::MapData.world is the only coordinate conversion); nothing here recomputes them.
import type { Theme } from "../themes/schema.ts";
import type { TileParts } from "./track-axes.ts";

export type HexKind = "land" | "sea" | "offboard";

/** A hex carries the track parts of its printed tile (paths, cities, towns, ...; rotation 0) as /map delivers them. */
export interface MapHex extends TileParts {
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
  /** Icons of the printed tile (image name as the engine has it, e.g. `18_oe/offshore_docks`). */
  icons?: { image: string; name?: string }[];
  /** Edge borders; type "province" separates track-rights zones. */
  borders?: { edge: number; type: string; cost?: number }[];
  /** Line inside the hex between two vertices a, b (engine: 0 = bottom vertex, clockwise). */
  partitions?: { a: number; b: number; type: string; length?: number | null }[];
}

/** One entry of `ports` in /map (Oe::MapData#ports): a hex side or the offshore port, its kind, and ferry ends. */
export interface PortEntry {
  hex: string;
  edge: number | string;
  port?: string;
  ferries?: { hex: string; exit: number | string; distance: number }[];
  dead_end?: boolean;
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
  /** Tile catalog by tile name: colour and track parts (laid tiles are drawn from these, #146). */
  tiles?: Record<string, TileParts & { color?: string }>;
  /** Ports and ferry ends (#452). */
  ports?: PortEntry[];
  /** Sea zones with the sea each belongs to (north_sea, mediterranean) and their hexes (#449). */
  sea_zones?: { name: string; sea: string; hexes: string[] }[];
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
