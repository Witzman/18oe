// Sea zones on the map (#449, the sea of input/map/map.jpg): the sea is one continuous surface tinted by its sea
// (the north seas light blue, the Mediterranean and the Black Sea turquoise), the sea zones are told apart by white
// dashed boundary lines, and each zone carries a circle with its city limit "-1". Pure geometry from the /map data
// (hex `sea_zone`, `sea_zones` with the sea of each zone); the drawing is static.ts.
import type { MapHex } from "./mapdata.ts";
import type { Vec } from "./projection.ts";

export type SeaGroup = "north_sea" | "mediterranean";

export interface SeaZone { name: string; sea: string; hexes: string[] }

/** The sea (tint group) of every sea hex that belongs to a zone. */
export function seaOfHex(zones: readonly SeaZone[] | undefined): Map<string, string> {
  const out = new Map<string, string>();
  for (const z of zones ?? []) for (const id of z.hexes) out.set(id, z.sea);
  return out;
}

/** A hex side between two sea hexes of different zones: the boundary of a zone, each side once. */
export interface ZoneBorder { hex: string; edge: number }

export function zoneBorders(hexes: readonly MapHex[]): ZoneBorder[] {
  const byId = new Map(hexes.map((h) => [h.id, h]));
  const out: ZoneBorder[] = [];
  for (const h of hexes) {
    if (!h.sea_zone) continue;
    h.neighbors.forEach((nid, edge) => {
      const n = nid ? byId.get(nid) : undefined;
      if (!n || !n.sea_zone || n.sea_zone === h.sea_zone || n.id < h.id) return;
      out.push({ hex: h.id, edge });
    });
  }
  return out;
}

/**
 * One mark per zone: the hex of the zone nearest to the centre of its hexes, so the circle sits inside the water
 * (a zone that wraps round an island has its centre on land: the nearest zone hex then). Hexes with a land
 * neighbour are only taken when the zone has no other.
 */
export function zoneMarks(hexes: readonly MapHex[]): { zone: string; hex: string; x: number; y: number }[] {
  const byId = new Map(hexes.map((h) => [h.id, h]));
  const byZone = new Map<string, MapHex[]>();
  for (const h of hexes) {
    if (!h.sea_zone) continue;
    const list = byZone.get(h.sea_zone);
    if (list) list.push(h);
    else byZone.set(h.sea_zone, [h]);
  }
  const out: { zone: string; hex: string; x: number; y: number }[] = [];
  for (const [zone, list] of byZone) {
    const cx = list.reduce((s, h) => s + h.x, 0) / list.length, cy = list.reduce((s, h) => s + h.y, 0) / list.length;
    const open = list.filter((h) => h.neighbors.every((nid) => !nid || byId.get(nid)?.kind === "sea"));
    const pool = open.length ? open : list;
    const best = pool.reduce((b, h) => (Math.hypot(h.x - cx, h.y - cy) < Math.hypot(b.x - cx, b.y - cy) ? h : b), pool[0]!);
    out.push({ zone, hex: best.id, x: best.x, y: best.y });
  }
  return out.sort((a, b) => a.zone.localeCompare(b.zone));
}

/** The dashes of the line a to b: `dash` long, `gap` apart, starting with a dash; the last one is cut at b. */
export function dashes(a: Vec, b: Vec, dash: number, gap: number): [Vec, Vec][] {
  const len = Math.hypot(b.x - a.x, b.y - a.y);
  if (!(len > 0) || !(dash > 0)) return [];
  const ux = (b.x - a.x) / len, uy = (b.y - a.y) / len;
  const out: [Vec, Vec][] = [];
  for (let s = 0; s < len; s += dash + gap) {
    const e = Math.min(s + dash, len);
    out.push([{ x: a.x + ux * s, y: a.y + uy * s }, { x: a.x + ux * e, y: a.y + uy * e }]);
  }
  return out;
}
