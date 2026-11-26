// The add-on reads the fixed map from the engine in the page (#626), with the fields our server's Oe::MapData builds.
// The engine objects are stand-ins here, with the shapes upstream's compiled engine has.
import assert from "node:assert/strict";
import { test } from "node:test";
import { readGeometry } from "../addon/geometry.ts";

const NIL = { $to_s: () => "" };
/** A Ruby hash as Opal hands it out, as far as the reader asks. */
const hash = (...entries: [unknown, unknown][]) => ({
  $to_a: () => entries,
  $fetch: (key: unknown) => entries.find(([k]) => k === key)![1],
  "$[]": (key: unknown) => entries.find(([k]) => k === key)?.[1] ?? NIL,
});

const Part = {
  City: { name: "City" }, Town: { name: "Town" }, DoubleTown: { name: "DoubleTown" }, Offboard: { name: "Offboard" },
  Junction: { name: "Junction" }, Path: { name: "Path" }, Label: { name: "Label" }, Upgrade: { name: "Upgrade" },
  Border: { name: "Border" }, Partition: { name: "Partition" }, Icon: { name: "Icon" },
  RevenueCenter: { $const_get: () => ["white", "yellow", "green"] },
};
type Kind = keyof typeof Part;
const part = (kinds: Kind[], methods: Record<string, unknown> = {}) => ({
  "$is_a?": (c: unknown) => kinds.some((k) => Part[k] === c),
  "$edge?": () => false,
  ...methods,
});
const edge = (num: number) => ({ "$edge?": () => true, $num: () => num });
const flat = (value: number) => hash(["white", value], ["yellow", value], ["green", value]);
const path = (a: unknown, b: unknown, terminal: unknown = NIL) =>
  part(["Path"], { $a: () => a, $b: () => b, "$terminal?": () => terminal });
const tile = (name: string, color: string, parts: unknown[] = [], junction: unknown = NIL) =>
  ({ $name: () => name, $color: () => color, $parts: () => parts, $junction: () => junction });

function engine() {
  const city = part(["City"], { $revenue: () => hash(["white", 0], ["yellow", 30], ["green", 40]), $normal_slots: () => 2, $loc: () => NIL });
  const town = (loc: unknown = "center") => part(["Town"], { $revenue: () => flat(10), $loc: () => loc });
  const twins = [town(), town()];
  const double = part(["DoubleTown", "Town"], {
    $revenue: () => flat(10), $loc: () => "center", $towns: () => twins, $axis: () => 0, $revenue_locs: () => [1.5, 4.5],
  });

  const land = tile("A1", "white", [
    city,
    path(edge(0), city),
    path(edge(0), city),
    part(["Upgrade"], { $terrains: () => ["mountain"], $cost: () => 45 }),
    part(["Border"], { $edge: () => 3, $type: () => "province", $cost: () => NIL }),
    part(["Partition"], { $a: () => 0, $b: () => 3, $length: () => NIL, $type: () => "water" }),
    part(["Icon"], { $image: () => "/icons/port.svg", $name: () => "port" }),
    part(["Label"], { $to_s: () => "A" }),
  ]);
  const sea = tile("A3", "blue", [path(edge(2), edge(5), true)]);
  const doubleTile = tile("OE1", "yellow", [
    double, ...twins, path(edge(0), twins[0]), path(twins[1], edge(3)), path(twins[0], twins[1]),
  ]);
  const red = tile("B2", "red", [part(["Offboard"], { $revenue: () => flat(20) })]);

  const hexes: Record<string, unknown> = {};
  const hex = (id: string, t: unknown, neighbors: Record<number, string>, name: unknown = NIL) => {
    hexes[id] = {
      $id: () => id, $tile: () => t, $location_name: () => name,
      $all_neighbors: () => ({ "$[]": (e: number) => (neighbors[e] ? hexes[neighbors[e]!] : NIL) }),
    };
    return hexes[id];
  };
  const list = [
    hex("B2", red, {}, ""),
    hex("A3", sea, { 1: "A1" }),
    hex("A1", land, { 4: "A3" }, "Home Town"),
    hex("AA1", doubleTile, {}),
  ];

  const constants: Record<string, unknown> = {
    LAYOUT: "pointy",
    SEA_ZONES: { "Some Sea": { sea: "north_sea", hexes: ["A3"] } },
    PORTS: hash(["A3", hash([2, { port: "public" }], ["offshore", { hex: "A1", ferries: [{ hex: "A1", exit: 1, distance: 0 }] }])]),
  };
  const corp = (id: string, coordinates: unknown) => ({ $id: () => id, $type: () => "minor", $coordinates: () => coordinates });
  const built: unknown[] = [];
  const klass = {
    $const_get: (name: string) => constants[name],
    $new: (names: unknown) => {
      built.push(names);
      return {
        $hexes: () => list,
        $tiles: () => [doubleTile, tile("57", "yellow"), doubleTile],
        $corporations: () => [corp("X", "A1"), corp("Y", NIL)],
      };
    },
  };
  const Opal = {
    nil: NIL,
    JSON: { $generate: JSON.stringify },
    Engine: {
      Part,
      Hex: {
        $const_get: (name: string) => (name === "LETTERS" ? ["A", "B", "AA"]
          : hash(["pointy", hash([[-1, 1], 0], [[-2, 0], 1], [[-1, -1], 2], [[1, -1], 3], [[2, 0], 4], [[1, 1], 5])])),
      },
    },
  };
  // the page's own game: its hexes must not be read, laid tiles take borders and names with them
  const game = { $class: () => klass, $hexes: () => { throw new Error("the page's game was read"); } };
  return { Opal, game, built };
}

test("the map comes from a new game of the page's engine, never from the running one", () => {
  const { Opal, game, built } = engine();
  readGeometry(Opal, game);
  assert.deepEqual(built, [["p0", "p1", "p2"]]);
});

test("hexes carry position, kind, neighbours and printed parts, in row and column order", () => {
  const { Opal, game } = engine();
  const { hexes, layout } = readGeometry(Opal, game);
  assert.deepEqual(layout, {
    orientation: "pointy",
    edge_vectors: [[-0.866025, 1.5], [-1.732051, 0], [-0.866025, -1.5], [0.866025, -1.5], [1.732051, 0], [0.866025, 1.5]],
  });
  assert.deepEqual(hexes.map((h) => h.id), ["A1", "A3", "B2", "AA1"]);
  assert.deepEqual(hexes[0], {
    id: "A1", x: 0.866025, y: 0, kind: "land", color: "white", neighbors: [null, null, null, null, "A3", null], name: "Home Town",
    cities: [{ node: 0, slots: 2, revenue: { white: 0, yellow: 30, green: 40 } }],
    paths: [{ a: { edge: 0 }, b: { node: 0 } }],
    labels: ["A"],
    terrain: [{ types: ["mountain"], cost: 45 }],
    borders: [{ edge: 3, type: "province" }],
    partitions: [{ a: 0, b: 3, length: null, type: "water" }],
    icons: [{ image: "/icons/port.svg", name: "port" }],
  });
  assert.deepEqual(hexes[1], {
    id: "A3", x: 2.598076, y: 0, kind: "sea", color: "blue", neighbors: [null, "A1", null, null, null, null],
    sea_zone: "Some Sea", paths: [{ a: { edge: 2 }, b: { edge: 5 }, terminal: true }],
  });
  assert.equal(hexes[2]!.kind, "offboard");
  assert.deepEqual(hexes[2]!.offboards, [{ node: 0, revenue: 20 }]);
  assert.equal("name" in hexes[2]!, false, "an empty name is none");
  assert.deepEqual([hexes[3]!.x, hexes[3]!.y], [0.866025, 3]);
});

// As Oe::MapData: the double town is a town as well, its two inner towns are none, the path between them is none.
test("a double town is one node with an axis", () => {
  const { Opal, game } = engine();
  const found = readGeometry(Opal, game).hexes[3]!;
  assert.deepEqual(found.towns, [{ node: 0, revenue: 10, loc: "center" }]);
  assert.deepEqual(found.double_towns, [{ node: 0, axis: 0, revenue_loc: [1.5, 4.5], revenue: 10 }]);
  assert.deepEqual(found.paths, [{ a: { edge: 0 }, b: { node: 0 } }, { a: { node: 0 }, b: { edge: 3 } }]);
});

test("ports keep numbered and named sides apart; sea zones, the tile catalog and home hexes come along", () => {
  const { Opal, game } = engine();
  const geometry = readGeometry(Opal, game);
  assert.deepEqual(geometry.ports, [
    { hex: "A3", edge: 2, port: "public" },
    { hex: "A3", edge: "offshore", ferries: [{ hex: "A1", exit: 1, distance: 0 }] },
  ]);
  assert.deepEqual(geometry.sea_zones, [{ name: "Some Sea", sea: "north_sea", hexes: ["A3"] }]);
  assert.deepEqual(Object.keys(geometry.tiles!), ["57", "OE1"]);
  assert.equal(geometry.tiles!["57"]!.color, "yellow");
  assert.deepEqual(geometry.tiles!.OE1!.double_towns!.length, 1);
  assert.deepEqual(geometry.homes, [{ corporation: "X", type: "minor", hex: "A1" }]);
});
