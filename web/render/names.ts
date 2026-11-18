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
