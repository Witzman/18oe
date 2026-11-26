# Publishing the browser add-on

Nothing is published. This is what is ready and what only the owner can do.

## Packages

```sh
cd web
node pack-addon.mjs --geometry map.json --site --release 1.0.0    # -> web/dist-addon-release/
```

- `18oe-visual-map-1.0.0.zip` - the extension: for the stores, or to pass on (unpack, "Load unpacked").
- `18oe-visual-map-1.0.0-source.zip` - sources and `BUILD.md`; Mozilla asks for them because the code is minified.

Every upload to a store needs a higher `--release`. Without `--site` the package runs on a local server only.
`geometry` is `Oe::MapData.build` of the engine version that the site runs.

## Before the first upload

1. **Name and Firefox id.** `18OE Visual Map` is a proposal. The id `oe-map@18oe.local`
   (`build-addon.mjs`) cannot be changed after the first upload to Mozilla.
2. **Rights.** The package holds map data (hexes, tiles, names) derived from the 18OE game files of 18xx.games.
   The site's MIT license excludes the game titles; the rights holders' consent was given to the site, not to
   this extension. Ask before giving it to others.
3. **Test on 18xx.games.** The `--site` build has never run there.
4. **Screenshots.** At least one, 1280x800 or 640x400.
5. **Accounts.** Mozilla add-on developer account (free), Chrome Web Store developer account (one-time fee),
   Microsoft Partner Center for Edge (free).

## Per store

| Store | Upload | Visibility to pick first | Also asked for |
|---|---|---|---|
| Firefox (addons.mozilla.org) | extension zip | self-distributed ("unlisted"): Mozilla signs it, you pass the file on | source zip |
| Chrome Web Store | extension zip | Unlisted (install by link) | texts of `listing.md`, screenshot |
| Edge Add-ons | the same zip | - | texts, screenshot |

Safari (iPad, iPhone, Mac) is not prepared: it needs an Apple developer membership and an app wrapper.
Updates of a self-distributed Firefox file need an update address in the manifest; not prepared.

## Not checked

No upload to any store and no store review. No install of the packages in a real Chrome, Edge or Firefox. No
lint with Mozilla's `web-ext` (it would be a new dependency). Firefox for Android is not declared.
