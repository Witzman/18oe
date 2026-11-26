// Reading the game from the page of 18xx.games (#614; findings workshop #612). Runs in the page's own JavaScript
// world, read-only: no request, no write to the game. The objects are Opal's compiled Ruby: no types.
import type { Board } from "../render/board.ts";

/* The page's runtime and its engine objects. */
export type Opal = any;
export type PageGame = any;

/**
 * Reports the game the page shows. Every redraw goes through Snabberb::Component#update!, whose root store holds
 * it. Reported when it is another object (history navigation, undo) or has another number of actions: a move is
 * applied to the same object (`process_action` returns self).
 */
export function installHook(Opal: Opal, onGame: (game: PageGame) => void): void {
  const proto = Opal.Snabberb.Component.$$prototype;
  const original = proto["$update!"];
  let last: PageGame = null;
  let moves = -1;
  proto["$update!"] = function (this: any, ...args: unknown[]) {
    try {
      return original.apply(this, args);
    } finally {
      try {
        const game = this.root?.store?.["$[]"]("game");
        if (game && game !== Opal.nil) {
          const count: number = game.$raw_actions().length;
          if (game !== last || count !== moves) {
            last = game;
            moves = count;
            onGame(game);
          }
        }
      } catch (error) {
        console.warn("18OE map: could not read the game", error);
      }
    }
  };
}

/** The part of the game the map draws (render/board.ts); `map` as lib/oe/view.rb builds it. */
export function readBoard(Opal: Opal, game: PageGame): Board {
  const nil = (v: unknown) => v === Opal.nil || v === undefined || v === null;
  const hexes = [...game.$hexes()].sort((a, b) => (a.$id() < b.$id() ? -1 : a.$id() > b.$id() ? 1 : 0));
  const map: Board["map"] = [];
  for (const hex of hexes) {
    const tile = hex.$tile();
    const tokens: { city: number; corporations: string[] }[] = [];
    [...tile.$cities()].forEach((city: any, index: number) => {
      const corporations = [...city.$tokens()].filter((t: unknown) => !nil(t))
        .map((t: any) => (nil(t.$corporation()) ? null : t.$corporation().$id()));
      if (corporations.length) tokens.push({ city: index, corporations });
    });
    const patronage = tile.$patronage();
    if (tile.$name() === hex.$original_tile().$name() && !tokens.length && nil(patronage)) continue;
    map.push({
      hex: hex.$id(),
      tile: { name: String(tile.$name()), rotation: tile.$rotation(), color: String(tile.$color()) },
      tokens,
      ...(nil(patronage) ? {} : { patronage: JSON.parse(Opal.JSON.$generate(patronage)) }),
    });
  }
  const corporations = [...game.$corporations()].map((corp: any) => ({
    id: corp.$id(),
    name: String(corp.$full_name()),
    closed: corp["$closed?"]() === true,
    color: String(corp.$color()),
    text_color: String(corp.$text_color()),
    tokens: [...corp.$tokens()].map((token: any) => {
      const city = token.$city();
      const hex = nil(city) || nil(city.$hex()) ? null : city.$hex().$id();
      const used = token.$used();
      return { used: !nil(used) && used !== false, hex };
    }),
  }));
  const rows = [...game.$stock_market().$market()].map((row: any) => [...row].map((cell: any) =>
    nil(cell) ? null : {
      price: cell.$price(),
      type: nil(cell.$type()) ? null : String(cell.$type()),
      corporations: [...cell.$corporations()].map((corp: any) => corp.$id()),
    }));
  return { map, corporations, phase_tiles: [...game.$phase().$tiles()].map(String), market: { rows } };
}

/**
 * Marks the market grid in what View::Game::StockMarket draws (a snabbdom node), so that place.ts finds it: the
 * page gives it no id; it is the one child that spans the width and scrolls.
 */
export function tagMarket(node: any): void {
  for (const child of node?.children ?? []) {
    const style = child?.data?.style;
    if (style?.width === "100%" && style?.overflow === "auto") {
      child.data.attrs = { ...child.data.attrs, "data-oe-market": "1" };
    }
  }
}

const tagged = new WeakSet<object>();

/**
 * Tags the grid wherever the page draws the market of an 18OE game (market tab, stock and auction views). False
 * while the page's views are not loaded (they come with its second script): ask again.
 */
export function installMarketTag(Opal: Opal, title: string): boolean {
  const proto = Opal.View?.Game?.StockMarket?.$$prototype;
  if (!proto) return false;
  if (tagged.has(proto)) return true;
  tagged.add(proto);
  const original = proto["$render"];
  proto["$render"] = function (this: any, ...args: unknown[]) {
    const node = original.apply(this, args);
    try {
      if (String(this.game.$class().$title()) === title) tagMarket(node);
    } catch (error) {
      console.warn("18OE market: could not mark the page's market", error);
    }
    return node;
  };
  return true;
}
