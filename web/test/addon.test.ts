// The browser add-on's shell (#614): reading the game from the page of 18xx.games and putting our map where the
// page's map is. The page's engine objects and the DOM are stand-ins here; the shapes are those of upstream.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { buildAddon } from "../build-addon.mjs";
import { boardNode, boardStyles } from "../addon/market.ts";
import { installHook, installMarketTag, readBoard, tagMarket } from "../addon/page.ts";
import { attachMap, attachMarket } from "../addon/place.ts";
import { find, textOf } from "../ui/kit/vnode.ts";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");

// ---- stand-ins for the Opal objects of the page --------------------------------------------------
const NIL = { nil: true };

function city(tokens: unknown[], hex: string) {
  return { $tokens: () => tokens, $hex: () => ({ $id: () => hex }) };
}

function pageGame(actions: unknown[] = []) {
  const corp = (id: string) => ({
    $id: () => id, $full_name: () => `${id} Railway`, "$closed?": () => false, $color: () => "#A0522D", $text_color: () => "#ffffff",
    $tokens: () => [{ $city: () => city([], "J79"), $used: () => true }, { $city: () => NIL, $used: () => NIL }],
  });
  const chn = corp("CHN");
  const token = { $corporation: () => chn };
  const hex = (id: string, tileName: string, cities: unknown[], patronage: unknown = NIL) => ({
    $id: () => id,
    $original_tile: () => ({ $name: () => id }),
    $tile: () => ({ $name: () => tileName, $rotation: () => 2, $color: () => "yellow", $cities: () => cities, $patronage: () => patronage }),
  });
  return {
    $class: () => ({ $title: () => "18OE" }),
    $raw_actions: () => actions,
    $hexes: () => [hex("K1", "K1", [city([NIL], "K1")]), hex("J79", "57", [city([NIL, token], "J79")]), hex("A2", "A2", [])],
    $corporations: () => [chn],
    $phase: () => ({ $tiles: () => ["yellow"] }),
    $stock_market: () => ({ $market: () => [
      [NIL, { $price: () => 110, $type: () => NIL, $corporations: () => [] }],
      [{ $price: () => 90, $type: () => "par", $corporations: () => [chn] }],
    ] }),
  };
}

function opal() {
  const calls: string[] = [];
  const proto: Record<string, unknown> = {
    "$update!"(this: unknown) { calls.push("drawn"); return "result"; },
  };
  return { Opal: { nil: NIL, JSON: { $generate: JSON.stringify }, Snabberb: { Component: { $$prototype: proto } } }, proto, calls };
}

const redraw = (proto: Record<string, unknown>, game: unknown) => {
  const root = { store: { "$[]": (key: string) => (key === "game" ? game : NIL) } };
  return (proto["$update!"] as (this: unknown) => unknown).call({ root });
};

test("the board read from the page: changed hexes sorted, tokens, companies with colours, phase", () => {
  const { Opal } = opal();
  assert.deepEqual(readBoard(Opal, pageGame()), {
    map: [{ hex: "J79", tile: { name: "57", rotation: 2, color: "yellow" }, tokens: [{ city: 0, corporations: ["CHN"] }] }],
    corporations: [{ id: "CHN", name: "CHN Railway", closed: false, color: "#A0522D", text_color: "#ffffff",
      tokens: [{ used: true, hex: "J79" }, { used: false, hex: null }] }],
    phase_tiles: ["yellow"],
    market: { rows: [[null, { price: 110, type: null, corporations: [] }], [{ price: 90, type: "par", corporations: ["CHN"] }]] },
  });
});

test("a redraw reports the game once, and again after a move on the very same game object", () => {
  const { Opal, proto, calls } = opal();
  const seen: unknown[] = [];
  installHook(Opal, (game) => seen.push(game));
  const actions: unknown[] = [];
  const game = pageGame(actions);

  assert.equal(redraw(proto, game), "result");
  redraw(proto, game);
  assert.equal(seen.length, 1, "nothing changed: not reported again");
  actions.push({});
  redraw(proto, game);
  assert.equal(seen.length, 2, "the page applies a move to the same object (process_action returns self)");
  redraw(proto, pageGame([{}]));
  assert.equal(seen.length, 3, "history navigation brings another object");
  assert.equal(calls.length, 4, "the page's own drawing always runs");
});

test("an error while reading never reaches the page", () => {
  const { Opal, proto } = opal();
  installHook(Opal, () => { throw new Error("boom"); });
  assert.equal(redraw(proto, pageGame()), "result");
});

// ---- placing the map ------------------------------------------------------------------------------
class Node {
  children: Node[] = [];
  parentNode: Node | null = null;
  style: Record<string, string> = {};
  attributes: Record<string, string> = {};
  textContent = "";
  onclick: (() => void) | null = null;
  tag: string;
  constructor(tag: string) { this.tag = tag; }
  get isConnected(): boolean { return this.tag === "body" || !!this.parentNode?.isConnected; }
  get nextSibling(): Node | null { const s = this.parentNode?.children ?? []; return s[s.indexOf(this) + 1] ?? null; }
  setAttribute(k: string, v: string) { this.attributes[k] = v; }
  insertBefore(node: Node, before: Node | null) {
    node.parentNode?.children.splice(node.parentNode.children.indexOf(node), 1);
    node.parentNode = this;
    this.children.splice(before ? this.children.indexOf(before) : this.children.length, 0, node);
    return node;
  }
  append(...nodes: Node[]) { for (const n of nodes) this.insertBefore(n, null); }
  remove() { this.parentNode?.children.splice(this.parentNode.children.indexOf(this), 1); this.parentNode = null; }
}

/** The page's markup: <div><zoom/><div scroller><svg id=map/></div><controls/></div> */
function page() {
  const body = new Node("body"), view = new Node("div"), scroller = new Node("div"), svg = new Node("svg");
  body.append(view);
  view.append(new Node("zoom"), scroller, new Node("controls"));
  scroller.append(svg);
  let map: Node | null = svg;
  const document = {
    createElement: (tag: string) => new Node(tag),
    getElementById: (id: string) => (id === "map" && map?.isConnected ? map : null),
    querySelector: (_selector: string): Node | null => null,
  };
  return { body, view, scroller, document, dropMap: () => { scroller.remove(); map = null; } };
}

const memory = () => { const data: Record<string, string> = {}; return { getItem: (k: string) => data[k] ?? null, setItem: (k: string, v: string) => { data[k] = v; } }; };

test("our map goes right before the page's map, which is hidden; calling again changes nothing", () => {
  const p = page();
  const placed = attachMap(p.document as never, memory());
  assert.equal(placed.sync(), true);
  assert.equal(placed.sync(), true);
  const box = placed.box as unknown as Node;
  assert.equal(p.view.children.filter((c) => c === box).length, 1);
  assert.equal(box.nextSibling, p.scroller);
  assert.equal(p.scroller.style.display, "none");
});

// On the Game tab the page's map sits in a column of width max-content: the page's map brings its own width, the
// canvas of ours (positioned absolutely) brings none, so the column shrank to the buttons below the map.
test("our box asks for the whole width the page offers, and no more", () => {
  const p = page();
  const placed = attachMap(p.document as never, memory());
  placed.sync();
  const box = placed.box as unknown as Node;
  assert.equal(box.style.width, "100vw", "its own width, so a shrink-to-content column grows");
  assert.equal(box.style.maxWidth, "100%", "never wider than the place it is in");
});

test("the switch shows the page's own map for actions, and the choice is remembered", () => {
  const p = page(), store = memory();
  const placed = attachMap(p.document as never, store);
  placed.sync();
  const button = (placed.box as unknown as Node).children[0]!.children[0]!;
  assert.equal(button.textContent, "Original map");
  button.onclick!();
  assert.equal(p.scroller.style.display, "");
  assert.equal((placed.stage as unknown as Node).style.display, "none");
  assert.equal(button.textContent, "18OE map");

  const again = attachMap(page().document as never, store);
  again.sync();
  assert.equal((again.stage as unknown as Node).style.display, "none", "remembered");
});

test("without a map on the page (another tab) nothing is placed; it comes back with the map", () => {
  const p = page();
  const placed = attachMap(p.document as never, memory());
  placed.sync();
  p.dropMap();
  assert.equal(placed.sync(), false);
  assert.equal((placed.box as unknown as Node).isConnected, false, "no stale map on another tab");
  assert.equal(p.scroller.style.display, "", "the page may reuse the element: leave it as it was");
});

test("a map that cannot be drawn leaves the page's map visible and says why", () => {
  const p = page();
  const placed = attachMap(p.document as never, memory());
  placed.sync();
  placed.fail("no webgl");
  assert.equal(p.scroller.style.display, "");
  assert.match((placed.box as unknown as Node).children[0]!.children[1]!.textContent, /no webgl/);
});

// ---- the stock market (#619) ------------------------------------------------------------------------
const marketBoard = () => readBoard(opal().Opal, pageGame());

test("the market board shows every price in its place and the companies as seals in their 18xx colours", () => {
  const node = boardNode(marketBoard());
  const cells = find(node, (n) => (n.attrs.class ?? "").split(" ").includes("stock-cell") && !!n.attrs["data-price"]);
  assert.deepEqual(cells.map((c) => c.attrs["data-price"]), ["110", "90"]);
  assert.equal(find(node, (n) => (n.attrs.class ?? "").includes("stock-cell-empty")).length, 2, "gaps keep the grid square");
  const [seal] = find(node, (n) => (n.attrs.class ?? "").includes("kit-seal"));
  assert.equal(textOf(seal!), "CHN");
  assert.match(seal!.attrs.style!, /--seal-bg:#a0522d/);
  assert.match(seal!.attrs.title!, /CHN Railway/);
});

test("it only shows: the legend has no entry for choosing a par or previewing a sale", () => {
  const node = boardNode(marketBoard());
  assert.deepEqual(find(node, (n) => n.tag === "li").map((li) => li.attrs["data-type"] ?? li.attrs["data-mark"]), ["par", "convert_range", "arrow"]);
});

test("a tap on a cell with companies opens their list, and it closes again", () => {
  const board = marketBoard();
  let opened: string | null = "unset";
  const [cell] = find(boardNode(board, null, (c) => { opened = c; }), (n) => n.tag === "button" && n.attrs["data-price"] === "90");
  cell!.on.click!({} as Event);
  assert.equal(opened, "1,0");
  const list = boardNode(board, "1,0", (c) => { opened = c; });
  assert.match(textOf(list), /CHN Railway/);
  const close = find(list, (n) => n.tag === "button" && (n.attrs.class ?? "").includes("kit-side-btn"))[0]!;
  close.on.click!({} as Event);
  assert.equal(opened, null);
});

test("our styles stay inside their own tree: nothing speaks to the page's root or body", () => {
  const css = boardStyles(":root { --kit-table-max: 16rem; }\nbody { margin: 0 }\nbody:has(.access) #app { margin: 0 }\n:root[data-tile-style=\"inner\"] .sw { top: 0 }");
  assert.match(css, /:host\s*{[^}]*--ui-bg:/, "the theme's colours");
  assert.match(css, /:host \{ --kit-table-max/);
  assert.doesNotMatch(css, /:root|(^|\n)body/);
});

// In the web UI the board's stage fills a positioned area (absolute, inset 0); in the page that area has no height.
test("the board takes its own height in the page", () => {
  const css = boardStyles(".stock-stage { position: absolute; inset: 0; }");
  assert.ok(css.lastIndexOf(".stock-stage { position: relative; inset: auto; }") > css.indexOf("position: absolute"), "overrides the web UI's rule");
});

test("the page's market grid is tagged where it is drawn, nothing else", () => {
  const grid = { sel: "div", data: { style: { width: "100%", overflow: "auto" }, attrs: { id: "keep" } }, children: [] };
  const bank = { sel: "div", data: { style: { marginBottom: "1rem" } }, children: [] };
  const root = { sel: "div", data: {}, children: [bank, grid] };
  tagMarket(root);
  assert.deepEqual(grid.data.attrs, { id: "keep", "data-oe-market": "1" });
  assert.equal((bank.data as { attrs?: unknown }).attrs, undefined);
  tagMarket(null);
});

// The page's views come with its second script, after the UI library the add-on waits for.
test("the market view is tagged once it exists, however often it is asked", () => {
  const Opal: Record<string, unknown> = {};
  assert.equal(installMarketTag(Opal, "18OE"), false, "not loaded yet");
  const grid = () => ({ data: { style: { width: "100%", overflow: "auto" } } as { style: object; attrs?: object } });
  let draws = 0;
  const proto = { $render() { draws += 1; return { children: [grid()] }; } };
  Opal.View = { Game: { StockMarket: { $$prototype: proto } } };
  assert.equal(installMarketTag(Opal, "18OE"), true);
  const wrapped = proto.$render;
  assert.equal(installMarketTag(Opal, "18OE"), true);
  assert.equal(proto.$render, wrapped, "wrapped once");
  const node = proto.$render.call({ game: pageGame() } as never) as { children: { data: { attrs?: object } }[] };
  assert.deepEqual(node.children[0]!.data.attrs, { "data-oe-market": "1" });
  const other = proto.$render.call({ game: { $class: () => ({ $title: () => "1889" }) } } as never) as typeof node;
  assert.equal(other.children[0]!.data.attrs, undefined, "other titles stay untouched");
  assert.equal(draws, 2);
});

test("the market has its own switch and memory, and sits before the page's grid", () => {
  const p = page(), store = memory();
  p.document.querySelector = (selector: string) => (selector === "[data-oe-market]" ? p.scroller : null);
  const market = attachMarket(p.document as never, store);
  assert.equal(market.sync(), true);
  const box = market.box as unknown as Node;
  assert.equal(box.nextSibling, p.scroller);
  const button = box.children[0]!.children[0]!;
  assert.equal(button.textContent, "Original market");
  button.onclick!();
  assert.equal(button.textContent, "18OE market");
  const map = attachMap(p.document as never, store);
  map.sync();
  assert.equal((map.stage as unknown as Node).style.display, "", "the map's choice is its own");
});

// ---- the unpacked extension -----------------------------------------------------------------------
test("the build writes a Manifest V3 extension for the page world, by default for the local server only", async () => {
  const out = mkdtempSync(join(tmpdir(), "oe-addon-"));
  await buildAddon({ out, geometry: join(web, "test", "fixtures", "map-geometry.json") });
  const manifest = JSON.parse(readFileSync(join(out, "manifest.json"), "utf8"));
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.content_scripts, [{ matches: ["http://localhost/*", "http://127.0.0.1/*"], js: ["content.js"], run_at: "document_start", world: "MAIN" }]);
  assert.equal(manifest.permissions, undefined);
  assert.equal(manifest.host_permissions, undefined);
  assert.ok(manifest.browser_specific_settings.gecko.id);
  const content = readFileSync(join(out, "content.js"), "utf8");
  assert.ok(content.includes("J79"), "the fixed map is inside");
  assert.doesNotMatch(content, /\bfetch\(["']https?:/);

  await buildAddon({ out, geometry: join(web, "test", "fixtures", "map-geometry.json"), site: true });
  assert.ok(JSON.parse(readFileSync(join(out, "manifest.json"), "utf8")).content_scripts[0].matches.includes("https://18xx.games/*"));
});
