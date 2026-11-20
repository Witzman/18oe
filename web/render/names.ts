// Place names on the map (#455): every named hex carries a label with its name below the city, shown from a zoom on
// (theme `nameZoom`, for the iPad) and for the hex under the mouse at any zoom (desktop). Red off-board hexes carry
// their name in the revenue box (#453) and get no label.
import type { MapHex } from "./mapdata.ts";

export interface NameLabel { id: string; name: string }

export function nameLabels(hexes: readonly MapHex[]): NameLabel[] {
  return hexes.filter((h) => h.name && h.color !== "red").map((h) => ({ id: h.id, name: h.name! }));
}

export function nameVisible(o: { zoom: number; nameZoom: number; hovered: boolean }): boolean {
  return o.hovered || o.zoom >= o.nameZoom;
}

// Names of the board (#461, input/map/mapreal.png): the track-rights regions as large pale lettering on the land, the
// seas beside their zone circle. Text of the printed board, so the words are the board's. Assumption: the positions of
// the region names are read off the reference (world units, same system as the hex x/y); the board also names Bulgaria,
// Romania and Serbia, the Ottoman Empire and Greece, which the engine has no region for.
export interface BoardLabel { lines: string[]; x: number; y: number }

export const REGION_LABELS: readonly BoardLabel[] = [
  { lines: ["United Kingdom"], x: 24.4, y: 15.8 },
  { lines: ["Sweden, Norway", "and Denmark"], x: 45, y: 3.7 },
  { lines: ["Germany, Holland", "and Switzerland"], x: 43, y: 16.8 },
  { lines: ["Russia"], x: 69.8, y: 9.8 },
  { lines: ["France and Belgium"], x: 26.5, y: 27.5 },
  { lines: ["Austria-Hungary"], x: 50.9, y: 29 },
  { lines: ["Spain and Portugal"], x: 14, y: 37.5 },
  { lines: ["Italy"], x: 41.9, y: 36 },
  { lines: ["Bulgaria, Romania,", "and Serbia"], x: 61.6, y: 34.5 },
  { lines: ["Ottoman Empire"], x: 70.4, y: 42.4 },
  { lines: ["Greece"], x: 58.3, y: 46.7 },
];

/** A sea name under its zone circle: "North Atlantic (Silver Coast)" becomes two lines. `drop` is the distance of the first line from the circle's centre. */
export function seaLabel(zone: string, at: { x: number; y: number }, drop: number): BoardLabel {
  const m = /^(.*?)\s*\((.*)\)$/.exec(zone);
  return { lines: m ? [m[1]!, `(${m[2]})`] : [zone], x: at.x, y: at.y + drop };
}
