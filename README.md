# 18oe

Turn-based 18xx-style train game. Private project; process and design docs
live in the sibling `18oe-workshop` repo, not here — see `CLAUDE.md` for
the short version and the pointer.

## Local development

```sh
bin/setup   # gems into vendor/bundle, Node 22 into .tools/node (idempotent)
bin/test    # runs the test suites (rspec for now)
bin/script-game --spawn   # scripted game over the real HTTP API, report of executed round/step/action combinations (#132)
```

Docker is not required for tests. Everything stays inside the repo
(`vendor/bundle`, `.tools`, both gitignored); `bundle` and `node` need not
be in `PATH`.

## Screenshots (visual self-check)

```sh
cd web && npm run build && cd ..
bin/shot web/dist/index.html#/kit out.png --theme atlas --width 1280 --height 900 --full-page
bin/shot http://127.0.0.1:4567/#/kit out.png --wait-for ".kit" --eval 'document.body.classList.add("x")'
```

`bin/shot <url|file> <out.png>` renders with a headless Chromium and writes a PNG
(options: `--width --height --theme brett|atlas --tile-style full|inner --wait-for <selector>
--delay <ms> --eval <js> --full-page`; `bin/shot --help`). A local file is served from its
own directory as site root, so `web/dist/index.html#/kit` works without the Ruby server.
Camera values and the like go into the URL (query/hash) once the page reads them.
No dependencies: it talks the DevTools protocol itself. Needs the Debian packages
`chromium-headless-shell`, `fonts-liberation`, `fonts-dejavu-core` (or `OE_BROWSER=<binary>`).
Note: in the agent sandbox only the headless *shell* starts (`AF_UNIX` sockets are denied,
the full `chromium` needs one); WebGL runs in software (SwiftShader). The smoke test in
`web/test/shot.test.ts` is skipped when no browser is installed.

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

### Access (#208)

Accounts are registered at `POST /register` (`name`, `email`, `password`,
`code`) with the single invite code from `OE_INVITE_CODE`; `POST /login`
takes `login` (e-mail or name) and `password`. Passwords are stored as
salted scrypt hashes. Set `SESSION_SECRET` and `OE_INVITE_CODE` in Dokploy
(both are listed in `docker-compose.yml`; the app refuses to start without
them). Until someone has registered with the code, nobody can log in. No
confirmation mail and no password reset yet.

## Status

Walking skeleton only — `app.rb` answers `/healthz`, no game logic yet.
Ruby, Sinatra, Puma.
