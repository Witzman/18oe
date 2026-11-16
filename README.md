# 18oe

Turn-based 18xx-style train game. Private project; process and design docs
live in the sibling `18oe-workshop` repo, not here — see `CLAUDE.md` for
the short version and the pointer.

## Local development

```sh
bin/setup   # gems into vendor/bundle, Node 22 into .tools/node (idempotent)
bin/test    # runs the test suites (rspec for now)
bin/test fast     # fast PR stage locally (no seed games, no browser; ~95 s, 3 rspec processes)
bin/test changed  # only the specs and unit tests of changed files (--list shows the plan)
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

### iPad profile (#260)

```sh
bin/shot web/dist/index.html#/map?src=/map.json out.png --device ipad --orientation portrait
cd web && node --test test/ipad-browser.test.ts     # map scene under iPad profile, both orientations
```

`--device ipad` (iPad Pro 11, 834x1194) or `ipad-10.2` (810x1080), `--orientation landscape|portrait`:
viewport, devicePixelRatio 2, mobile, touch emulation, iPad Safari user agent. In `--eval`,
`await window.oeTouch("start"|"move"|"end", [{x,y,id}])` sends real touch input (taps, two-finger pinch).

**Engine status: real WebKit does NOT run in the agent sandbox yet; the iPad profile currently runs on
Chromium and is an APPROXIMATION** (right size/DPR/touch/UA, but Chromium's rendering, WebGL, viewport
units and touch handling, not Safari's; the real iPad stays the owner's playtest). `--engine auto` (default)
tries WebKit first and says on stderr which engine was used; `--engine webkit` fails instead of falling back.

Real WebKit setup (done once; the pieces except the system libraries are in place on this machine):
`mkdir -p .tools/pw && cd .tools/pw && npm i playwright-core@1.65.0 && PLAYWRIGHT_BROWSERS_PATH=$PWD/browsers node node_modules/playwright-core/cli.js install webkit`
(hosts: registry.npmjs.org, cdn.playwright.dev). WebKit then needs ~124 Debian system packages
(`sudo node node_modules/playwright-core/cli.js install-deps webkit`, root); list: `... install-deps --dry-run webkit`.
In the WebKit engine only `oeTouch("tap", [{x,y}])` exists.

**One browser at a time:** `bin/shot` (and so every browser test) takes the machine-wide
`flock` on `tmp/heavy.lock` of the main `18oe` checkout before it starts a browser; other heavy jobs
use `flock /home/witzman/18oe/tmp/heavy.lock <command>`. `OE_HEAVY_LOCK_HELD=1` skips it if you already hold it.

## Screenshots for the UI feedback board (#374)

`bin/boardshots [scene ...]` takes the scenes of `bin/boardshots.json` (a recorded game fixture each, served by a stub
API, no engine) with the real built UI (`cd web && npm run build` first) at 1747x923 into `tmp/board/<scene>.png`
(`OE_BOARD_OUT` changes the folder). Every scene is its own `bin/shot.mjs` run under a hard timeout and `heavy.lock`
(one browser at a time, foreground only). A new scene is a line in `bin/boardshots.json`; `web/test/boardshots.test.ts`
checks names and fixtures. The board page itself and how to publish it are in the workshop (`notes/ui-feedback/`).

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

## CI stages (#365)

Two stages, one definition of "fast": the RSpec tag `:game_flow` (spec/support/tags.rb).

| Stage | Workflow | When | What |
|---|---|---|---|
| fast | `ci.yml` | every pull request | rspec `--tag ~game_flow` (engine specs, contracts; = `bin/test fast`), typecheck, web unit tests, browser tests only if `web/**` changed (`touch-browser` excluded). Target: under 3 min |
| milestone | `full.yml` | nightly 02:17 UTC, tag `v0.*`, manually for any commit | the complete rspec suite (`:game_flow` included), long whole games uncapped, all browser tests incl. `touch-browser`, scripted game |

`full.yml` does NOT run on every push to `main`. To check `main` after a merge (or a deploy SHA), start it for
that commit: GitHub UI Actions > full > Run workflow (field `sha`), or

    python3 -c "import sys; sys.path.insert(0,'lib'); import github; github.post('/repos/Witzman/18oe/actions/workflows/full.yml/dispatches', ref='main', inputs={'sha': '<SHA>'})"

(in the workshop checkout). Read the result per job, not only the workflow status. Every example runs in at
least one stage: fast = `~game_flow`, milestone = all; `view_spec`, `view_order_spec` and `bot_spec` run
only in the `long games` jobs there (whole files, caps lifted), not additionally in the capped rspec shards.
Two more pieces (#365 B6). `catalog-refresh.yml` (`workflow_dispatch` only, fields `sha` and `games`; `concurrency` group
`catalog-refresh`, never cancelled, so refreshes run one after the other) rebuilds the stored catalog logs with the
current engine, writes `bin/fixture-catalog diff` per game into the step summary and uploads the new
`spec/fixtures/games/logs/` as the artifact `catalog-logs`; it pushes nothing. Download the artifact, commit it on a
branch `refresh/catalog-<date>`, open the one refresh PR. The milestone stage has a job `catalog live`
(`OE_CATALOG=live`: fixture catalog and invariants specs against fresh games instead of stored logs). Guard: the `changes`
job of `ci.yml` (an existing required check, no new check) fails a pull request that changes
`spec/fixtures/games/logs/*` unless its branch starts with `refresh/catalog-`.

The browser job of `ci.yml` always runs (a `changes` job decides: without a `web/**` change its steps are skipped and it ends green), so it can be a required check. Wall time of the fast stage: about 2 to 3 min (measured, PRs 157 and 159); milestone stage: about 7 to 8 min.

## Fixture catalog (#365)

`spec/fixtures/games/catalog.json` is the one definition: the games (players, seed, player kind,
`max_actions`), the entries (rule surface, slice, a finder such as `first: {round, step}`, `before: {type}`,
`at: 0`, plus `where`/`after`) and the gaps. It holds no positions. The stored game logs are
`spec/fixtures/games/logs/<game>.jsonl` (one accepted action per line) with `logs/manifest.json` (engine commit,
number of actions, sha256 and resolved positions per log, information for the refresh diff). The loader resolves
the finders against the log when it is first used. A log is written only by a catalog refresh PR (branch
`refresh/catalog-*`), never by a feature PR: `bin/fixture-catalog diff <game>` shows what a rebuild changes,
`bin/fixture-catalog build <game>` writes it (a game takes minutes; one game per call, under `timeout`).
`OE_CATALOG=live` plays fresh games instead of the stored logs; a stored log the engine no longer accepts raises
`log <game> stale at action K`.

## Versions, tags and changelog (#271)

The roadmap version (v0.1 to v0.9, see 18oe-workshop#20) lives in ONE file, `VERSION` in the repo
root (`0.1.0-dev` while a version is being built). `lib/oe/version.rb` and `web/build.mjs` read it;
nothing else repeats it. Where it shows:

- `GET /healthz` returns `status`, `build` (content hash, `bin/build-id` for the local tree), `web_build` (hash of the shipped `web/dist`, `bin/build-id --web` after `npm run build`; null without a bundle),
  `version` (from `VERSION`) and `engine` (engine revision: upstream commit + build id, the stamp new
  games get). Fields are only ever added.
- The UI: a footer line on the login/registration pages and a version button (top right, opens an info
  dialog) in the game frame. Page version is baked in at build time, build id and engine stand come from
  `/healthz` (the only runtime call). If page and server versions differ (old frontend in the browser
  cache) the display says so. Texts: `web/ui/text.ts` (`version.*`).
- Feedback and bug reports name the line "Version x · Build y · Engine z".

**Releasing a version** (done by the main session when a roadmap version is finished and accepted):

1. In a PR set `VERSION` to the final number (`0.1.0`, `0.2.0`, ...; sub-stages `0.2.1`), merge it.
2. Tag the merge commit on `main`, annotated, with `v<VERSION>`: `git tag -a v0.1.0 <merge-commit> -m "v0.1.0"`,
   `git push origin v0.1.0`. Tags go only on merge commits of `main`; never a `Co-Authored-By` or
   "Generated with" line in tag, release text or commit (workshop rule 5).
3. Create a GitHub Release for the tag; its text is the changelog. Put a short copy into #20.
4. Set `VERSION` to the next `-dev` value (`0.2.0-dev`) in the next PR.

Changelog template (German, as the project):

```
## v0.X.0 - <Kurztitel>
**Neu:** <was Spielerinnen und Spieler jetzt können; je Punkt ein Satz, mit Issue-Nummer>
**Bekannt fehlt:** <was erwartet wird und noch nicht geht; offene Issues der Version>
**Migration / Replay:** <Änderungen an der Datenbank; ändert sich die Engine, sind laufende Partien
noch abspielbar (#131)? sonst: laufende Partien vor dem Deploy beenden>
**Stand:** Build <build-id> - Engine <engine-stand> (aus /healthz nach dem Deploy)
```

## Status

Walking skeleton only — `app.rb` answers `/healthz`, no game logic yet.
Ruby, Sinatra, Puma.
