# Store listing (draft)

Texts to paste into the store forms. Name, wording and icon are first proposals.

## Name

18OE Visual Map

## Summary (also the manifest description, 132 characters at most)

Restyles the 18OE map and stock market on 18xx.games. Visual only: reads the page, sends nothing. Unofficial.

## Description

18OE Visual Map changes how games of 18OE (On the Rails of the Orient Express) look on 18xx.games:

- the map in a flat Belle Époque style,
- the stock market board in the same style.

A button above each view brings the original back at any time. Lay track and place tokens on the original map.

It is visual only. It reads the game that the page already shows and draws it differently, for you alone. It
makes no moves, changes nothing in the game and sends nothing anywhere. Games of other titles stay as they are.

This is an unofficial extension. It is not affiliated with or endorsed by 18xx.games or by the publisher of
the game.

## Single purpose

Show the map and the stock market board of an 18OE game on 18xx.games in a different visual style.

## Permissions and host access

The extension requests no permissions. Its one content script runs on the listed sites, because it has to read
the game on the game page and draw into that page. It runs in the page's own JavaScript world to reach the
game object there.

## Remote code

No. All code and fonts are inside the package.

## Data collection

None. No data is collected, transmitted, sold or shared.

## Privacy policy

18OE Visual Map does not collect, transmit or share any data. It reads the game shown on the page to draw it in
the browser. It stores two settings in the browser's local storage for the site: whether you last chose the
original or the restyled view, for the map and for the stock market. Removing the site data removes them.

## Notes for reviewers

- To see it work, open an 18OE game on 18xx.games (a hotseat game is enough) and look at the Map and Market tabs.
- `content.js` is bundled and minified by esbuild; the sources and the build command are in the source package
  (`BUILD.md`).
- `THIRD_PARTY_LICENSES.txt` lists the bundled libraries and fonts.
