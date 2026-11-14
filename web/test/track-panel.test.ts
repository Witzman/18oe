// Track panel (#48): the pure model on a recorded real state (track-lay = minor M in its first operating
// round, two buildable hexes, three tiles each, recorded with Oe::View from a strategy game) plus the tile
// picture. Acceptance (#278): every offered lay is reachable through the panel, nothing else can be sent.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { Game } from "../types.ts";
import { createClaims } from "../ui/frame/claims.ts";
import { genericModel } from "../ui/frame/generic.ts";
import { find, textOf } from "../ui/kit/vnode.ts";
import { hexFrame } from "../render/track-axes.ts";
import { curvePath, hexCorners, tileSvg } from "../render/tile-svg.ts";
import { tileName } from "../render/preview.ts";
import {
  TrackPanel, effectiveSelection, emptySelection, orderFor, previewFor, sentenceFor, tapHex, targetsFor, trackHexes, turn, type TrackSelection,
} from "../ui/panels/track.ts";

const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/games/${n}.json`, import.meta.url), "utf8")) as Game;
const tiles = JSON.parse(readFileSync(new URL("./fixtures/map-tiles.json", import.meta.url), "utf8")).tiles;
const layout = JSON.parse(readFileSync(new URL("./fixtures/map-geometry.json", import.meta.url), "utf8")).layout;
const noop = { onHex: () => {}, onTile: () => {}, onTurn: () => {}, onMap: () => {} };
const key = (a: Record<string, unknown> | null) => (a ? JSON.stringify([a.hex, a.tile, a.rotation]) : "null");
const lays = (g: Game) => g.state.prompt.actions.filter((a) => a.type === "lay_tile");

test("hexes: grouped from prompt.actions, enriched with cost and points from context.track", () => {
  const g = load("track-lay");
  const hexes = trackHexes(g, tiles);
  assert.deepEqual(hexes.map((h) => h.hex), ["E86", "I86"]);
  const i86 = hexes[1]!;
  assert.equal(i86.cost, 24);
  assert.equal(i86.points, 1);
  assert.deepEqual(i86.costParts.map((p) => p.label), ["hill", "discount"]);
  assert.deepEqual(i86.tiles.map((t) => [t.id, t.name, t.color, t.rotations.map((r) => r.rotation)]),
    [["7-7", "7", "yellow", [2]], ["8-8", "8", "yellow", [1, 3]], ["9-4", "9", "yellow", [0, 3]]]);
  assert.deepEqual(targetsFor(g, tiles), { hexes: ["E86", "I86"], kind: "track" });
});

test("acceptance: every offered lay is reachable by taps and buttons, no other action can be confirmed", () => {
  const g = load("track-lay");
  const reached = new Set<string>();
  for (const h of trackHexes(g, tiles)) {
    let sel: TrackSelection = tapHex(g, emptySelection(), h.hex, tiles)!;
    for (const t of h.tiles) {
      sel = effectiveSelection(g, { ...sel, tile: t.id, rotation: null }, tiles);
      for (let i = 0; i < t.rotations.length + 1; i++) {
        const s = sentenceFor(g, sel, tiles);
        assert.ok(s.action, "a whole selection has an action");
        reached.add(key(s.action));
        sel = turn(g, sel, 1, tiles);
      }
    }
  }
  assert.deepEqual([...reached].sort(), lays(g).map(key).sort());
  // Selections outside the offer collapse to an offered one or to nothing.
  for (const bad of [{ hex: "A2", tile: "9-4", rotation: 0 }, { hex: "I86", tile: "57-0", rotation: 1 }, { hex: "I86", tile: "9-4", rotation: 4 }]) {
    const a = sentenceFor(g, bad, tiles).action;
    assert.ok(a === null || lays(g).some((x) => key(x) === key(a)), `bad selection sends ${key(a)}`);
  }
});

test("taps: first tap picks the hex with its first tile, the same hex again turns it, a dead hex is ignored", () => {
  const g = load("track-lay");
  const a = tapHex(g, emptySelection(), "I86", tiles)!;
  assert.deepEqual(a, { hex: "I86", tile: "7-7", rotation: 2 });
  const b = tapHex(g, { ...a, tile: "8-8", rotation: 1 }, "I86", tiles)!;
  assert.deepEqual(b, { hex: "I86", tile: "8-8", rotation: 3 });
  assert.equal(turn(g, b, 1, tiles).rotation, 1, "wraps around");
  assert.equal(turn(g, b, -1, tiles).rotation, 1);
  assert.equal(tapHex(g, a, "A2", tiles), null);
});

test("preview and order: catalog name and rotation on the map; nothing confirmable before a pick; sentence with cost and points", () => {
  const g = load("track-lay");
  assert.equal(previewFor(g, emptySelection(), tiles), null);
  const sent: unknown[] = [];
  const none = orderFor(g, emptySelection(), (x) => sent.push(x), () => {}, tiles)!;
  assert.equal(none.state, "invalid");
  assert.deepEqual(none.side!.map((s) => s.label), ["Gleisbau beenden"]);
  const sel = { hex: "I86", tile: "9-4", rotation: 3 };
  assert.deepEqual(previewFor(g, sel, tiles), { hex: "I86", tile: "9", rotation: 3 });
  const o = orderFor(g, sel, (x) => sent.push(x), () => {}, tiles)!;
  assert.equal(o.state, "preview");
  assert.match(o.sentence, /M legt Kachel 9 auf I86, Drehung 2 von 2, für £24/);
  const cash = g.state.corporations.find((c) => c.id === "M")!.cash;
  assert.deepEqual(o.changes!.map((c) => [c.label, c.before, c.after]), [["Kasse M", `£${cash}`, `£${cash - 24}`], ["Baupunkte", "3", "2"]]);
  assert.deepEqual(o.side!.map((s) => s.label), ["Drehen ↻", "Gleisbau beenden"]);
  assert.equal(sent.length, 0, "building the order sends nothing");
  o.onConfirm();
  assert.deepEqual(sent, [lays(g).find((a) => a.hex === "I86" && a.tile === "9-4" && a.rotation === 3)]);
});

test("claims: with the panel mounted the generic bar offers nothing of the track step", () => {
  const g = load("track-lay");
  const claims = createClaims();
  claims.claim("Track", "lay_tile");
  claims.claim("Track", "pass");
  assert.equal(genericModel(g, claims).count, 0);
});

test("panel: hex rows, drawn tiles with names, rotation group; others see only who builds", () => {
  const g = load("track-lay");
  const geometry = { layout, hexes: [], tiles };
  const p = TrackPanel(g, { hex: "I86", tile: "8-8", rotation: 3 }, noop, geometry);
  assert.match(textOf(p), /Baupunkte: 3 von 3 übrig/);
  assert.deepEqual(find(p, (n) => n.attrs.class === "track-hex").map((n) => n.attrs["data-hex"]), ["E86", "I86"]);
  const tileBtns = find(p, (n) => n.attrs.class === "track-tile");
  assert.deepEqual(tileBtns.map((n) => [n.attrs["data-tile"], n.attrs["aria-pressed"]]), [["7-7", "false"], ["8-8", "true"], ["9-4", "false"]]);
  assert.equal(find(p, (n) => n.tag === "svg").length, 3);
  assert.match(textOf(p), /Drehung 2 von 2/);
  assert.match(textOf(p), /Kosten £24 \(hill £30, Nachlass /);
  const other = structuredClone(g);
  other.state.prompt.viewer_to_act = false;
  other.state.prompt.actions = [];
  assert.match(textOf(TrackPanel(other, emptySelection(), noop, geometry)), /M baut Gleis/);
  assert.equal(orderFor(other, emptySelection(), () => {}, () => {}, tiles), null);
});

test("tile picture: hex polygon, one path per track axis, arcs as SVG arcs, cities as slot circles", () => {
  const frame = hexFrame(layout.edge_vectors);
  assert.equal(hexCorners(frame).length, 6);
  for (const c of hexCorners(frame)) assert.ok(Math.abs(Math.hypot(c.x, c.y) - frame.side) < 1e-9);
  const svg = tileSvg(tiles["8"], 1, frame, { color: "yellow", label: "Kachel 8" });
  assert.equal(svg.tag, "svg");
  const paths = find(svg, (n) => n.tag === "path");
  assert.equal(paths.length, tiles["8"].paths.length);
  assert.match(paths[0]!.attrs.d!, /^M [-\d.]+ [-\d.]+ A /);
  assert.match(find(svg, (n) => n.tag === "polygon")[0]!.attrs.fill!, /--map-tile-yellow/);
  assert.match(curvePath({ kind: "line", p0: { x: 0, y: 0 }, p1: { x: 1, y: 2 } }), /^M 0 0 L 1 2$/);
  const city = Object.keys(tiles).find((k) => tiles[k].cities?.some((c: { slots?: number }) => (c.slots ?? 1) === 2))!;
  assert.ok(find(tileSvg(tiles[city], 0, frame, {}), (n) => n.tag === "circle").length >= 2);
  assert.equal(tileName("9-4", tiles), "9");
  assert.equal(tileName("OE4", tiles), "OE4");
});
