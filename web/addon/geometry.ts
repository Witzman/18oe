// The fixed map, read from the engine in the page (#626), so the add-on ships no map data. The fields and rules are
// those of our server's lib/oe/map_data.rb, as far as the renderer reads them. The source is a game made new for
// this: in the running one a laid tile takes the hex's borders and name with it. Opal's compiled Ruby: no types.
import type { MapGeometry, MapHex, PortEntry } from "../render/mapdata.ts";
import type { TileParts } from "../render/track-axes.ts";
import type { Opal, PageGame } from "./page.ts";

const round = (value: number) => Math.round(value * 1e6) / 1e6;
/** A hex's centre in side lengths, y down (Oe::MapData.world: neighbours in a row are two columns apart). */
const world = (row: number, col: number): [number, number] => [round(col * Math.sqrt(3) / 2), row * 1.5];

function reader(Opal: Opal) {
  const { Part } = Opal.Engine;
  const truthy = (v: unknown) => v !== Opal.nil && v !== undefined && v !== null && v !== false;
  const plain = (v: unknown) => JSON.parse(Opal.JSON.$generate(v));
  /** A name that may be missing: Ruby's nil.to_s. */
  const text = (v: unknown) => (v === Opal.nil ? "" : String(v));
  const phases: number = Opal.Engine.Part.RevenueCenter.$const_get("PHASES").length;

  /** One number when the revenue is the same in every phase, else { phase: n }. */
  function revenue(node: any) {
    const entries: [unknown, number][] = node.$revenue().$to_a();
    const same = entries.length === phases && entries.every(([, n]) => n === entries[0]![1]);
    return same ? entries[0]![1] : Object.fromEntries(entries.map(([phase, n]) => [String(phase), n]));
  }

  /** The parts of a tile at rotation 0; cities, towns, double towns, offboards and the junction are numbered nodes. */
  return function tileParts(tile: any): Partial<MapHex> & TileParts {
    const parts: any[] = [...tile.$parts()];
    const of = (kind: string) => parts.filter((p) => p["$is_a?"](Part[kind]) === true);
    const doubles = of("DoubleTown");
    const twinOf = new Map<unknown, unknown>(doubles.flatMap((d) => [...d.$towns()].map((t) => [t, d] as const)));
    const nodes = parts.filter((p) => ["City", "Town", "DoubleTown", "Offboard", "Junction"]
      .some((kind) => p["$is_a?"](Part[kind]) === true) && !twinOf.has(p));
    const node = (p: unknown) => {
      const index = nodes.indexOf(p);
      if (index < 0) throw new Error(`tile ${tile.$name()}: a path leads to no node`);
      return index;
    };
    const end = (e: any) => (truthy(e["$edge?"]()) ? { edge: e.$num() } : { node: node(twinOf.get(e) ?? e) });
    const place = (p: any) => (truthy(p.$loc()) ? { loc: typeof p.$loc() === "number" ? p.$loc() : String(p.$loc()) } : {});

    const paths = new Map<string, unknown>();
    for (const p of of("Path")) {
      const a = p.$a(), b = p.$b();
      if (twinOf.has(a) && twinOf.has(b)) continue;
      const path = { a: end(a), b: end(b), ...(truthy(p["$terminal?"]()) ? { terminal: true } : {}) };
      paths.set(JSON.stringify(path), path);
    }

    const lists: Record<string, unknown[]> = {
      cities: of("City").map((c) => ({ node: node(c), slots: c.$normal_slots(), revenue: revenue(c), ...place(c) })),
      towns: of("Town").filter((t) => !twinOf.has(t)).map((t) => ({ node: node(t), revenue: revenue(t), ...place(t) })),
      double_towns: doubles.map((d) => ({
        node: node(d), axis: d.$axis(), revenue_loc: plain(d.$revenue_locs()), revenue: revenue(d.$towns()[0]),
      })),
      offboards: of("Offboard").map((o) => ({ node: node(o), revenue: revenue(o) })),
      paths: [...paths.values()],
      labels: of("Label").map((l) => String(l.$to_s())),
      terrain: of("Upgrade").map((u) => ({ types: [...u.$terrains()].map(String), cost: u.$cost() })),
      borders: of("Border").map((b) => ({
        edge: b.$edge(), type: text(b.$type()), ...(truthy(b.$cost()) ? { cost: b.$cost() } : {}),
      })),
      partitions: of("Partition").map((p) => ({
        a: p.$a(), b: p.$b(), length: truthy(p.$length()) ? p.$length() : null, type: text(p.$type()),
      })),
      icons: of("Icon").map((i) => ({ image: String(i.$image()), ...(truthy(i.$name()) ? { name: String(i.$name()) } : {}) })),
    };
    const out: any = Object.fromEntries(Object.entries(lists).filter(([, list]) => list.length));
    if (truthy(tile.$junction())) out.junction = node(tile.$junction());
    return out;
  };
}

export function readGeometry(Opal: Opal, game: PageGame): MapGeometry {
  const klass = game.$class();
  const fresh = klass.$new(["p0", "p1", "p2"]);
  const constant = (name: string) => klass.$const_get(name);
  const plain = (v: unknown) => JSON.parse(Opal.JSON.$generate(v));
  const nil = (v: unknown) => v === Opal.nil || v === undefined || v === null;
  const tileParts = reader(Opal);
  const { Hex } = Opal.Engine;

  const letters: string[] = [...Hex.$const_get("LETTERS")].map(String);
  const directions: [[number, number], number][] = Hex.$const_get("DIRECTIONS").$fetch("pointy").$to_a();
  const edge_vectors = [0, 1, 2, 3, 4, 5].map((e) => {
    const [dx, dy] = directions.find(([, edge]) => edge === e)![0];
    return world(dy, dx);
  });

  const seaZones = Object.entries<{ sea: string; hexes: string[] }>(plain(constant("SEA_ZONES")))
    .map(([name, zone]) => ({ name, sea: zone.sea, hexes: zone.hexes }));
  const seaOf = new Map(seaZones.flatMap((z) => z.hexes.map((id) => [id, z.name] as const)));

  const placed = [...fresh.$hexes()].map((hex: any) => {
    const id = String(hex.$id());
    const row = letters.indexOf(id.match(/[A-Za-z]+/)![0]), col = Number(id.match(/\d+/)![0]);
    if (row < 0) throw new Error(`bad coordinates ${id}`);
    return { hex, id, row, col };
  }).sort((a, b) => a.row - b.row || a.col - b.col);
  const hexes: MapHex[] = placed.map(({ hex, id, row, col }) => {
    const tile = hex.$tile(), color = String(tile.$color()), sea = seaOf.get(id);
    const name = hex.$location_name();
    const [x, y] = world(row, col);
    return {
      id, x, y, color,
      kind: color === "red" ? "offboard" : color === "blue" || sea ? "sea" : "land",
      neighbors: [0, 1, 2, 3, 4, 5].map((e) => {
        const next = hex.$all_neighbors()["$[]"](e);
        return nil(next) ? null : String(next.$id());
      }),
      ...(!nil(name) && String(name) !== "" ? { name: String(name) } : {}),
      ...(sea ? { sea_zone: sea } : {}),
      ...tileParts(tile),
    };
  });

  const catalog = new Map<string, any>();
  for (const tile of fresh.$tiles()) if (!catalog.has(String(tile.$name()))) catalog.set(String(tile.$name()), tile);
  const tiles = Object.fromEntries([...catalog.keys()].sort()
    .map((name) => [name, { color: String(catalog.get(name).$color()), ...tileParts(catalog.get(name)) }]));

  // Sides are numbers or names (:offshore), and stay what they are. An offshore entry names a hex of its own (where
  // the port stands): not read, the port is listed under its table key.
  const ports: PortEntry[] = constant("PORTS").$to_a().flatMap(([hex, edges]: [string, any]) =>
    edges.$to_a().map(([edge, entry]: [number | string, unknown]) => {
      const { port, ferries, dead_end } = plain(entry);
      return { hex: String(hex), edge, ...(port ? { port } : {}), ...(ferries ? { ferries } : {}), ...(dead_end ? { dead_end } : {}) };
    }));

  const homes = [...fresh.$corporations()].flatMap((corp: any) => {
    const hex = corp.$coordinates();
    return nil(hex) ? [] : [{ corporation: String(corp.$id()), type: String(corp.$type()), hex: plain(hex) }];
  });

  return { layout: { orientation: String(constant("LAYOUT")), edge_vectors }, hexes, tiles, ports, sea_zones: seaZones, homes };
}
