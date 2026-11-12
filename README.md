# 18oe

Turn-based 18xx-style train game. Private project; process and design docs
live in the sibling `18oe-workshop` repo, not here — see `CLAUDE.md` for
the short version and the pointer.

## Local development

```sh
bin/setup   # gems into vendor/bundle, Node 22 into .tools/node (idempotent)
bin/test    # runs the test suites (rspec for now)
```

Docker is not required for tests. Everything stays inside the repo
(`vendor/bundle`, `.tools`, both gitignored); `bundle` and `node` need not
be in `PATH`.

## Rules engine

`lib/engine/` is the rules engine, extracted from the open-source
tobymao/18xx Ruby engine (MIT) and trimmed to the core plus the 18OE title,
loaded with plain `require 'engine'` (no `require_all` gem, no Opal). Source
commit, removals, the list of modified files and the license are in
`lib/engine/UPSTREAM.md`. Do not reformat or refactor it; keep the diff
against upstream explainable.

## Themes (frontend look)

Every visual decision is a token. A theme is one JSON file in `web/themes/`
(`brett.json`, `atlas.json`) with exactly the keys of `web/themes/schema.ts`:
map, panel, company and player colours, fonts, tilt, tile style, paper grain.
`npm run build` turns them into `dist/themes.css` (CSS variables per
`data-theme`); `web/render/theme.ts` gives the renderer the same values as
numbers. `web/theme.css` contains layout only and may not name a colour.

A new theme: copy a JSON file, change the values, list it in
`web/themes/index.ts`. `bin/test web` checks that it has every key and that
text reaches its contrast. The "Look" menu (bottom right) switches theme and
tile style; the pick is kept in `localStorage` (`oe.theme`, `oe.tileStyle`).
The build imports TypeScript directly and needs Node 22.18 or newer.

## Running with Docker

```sh
docker compose up --build
curl http://localhost/healthz
```

## Deployment

Runs on Dokploy (`orient18oe`), building this repo's `Dockerfile`/
`docker-compose.yml` directly. DNS/vhost routing (the server also runs
Apache for other domains) is being finished separately.

## Status

Walking skeleton only — `app.rb` answers `/healthz`, no game logic yet.
Ruby, Sinatra, Puma.
