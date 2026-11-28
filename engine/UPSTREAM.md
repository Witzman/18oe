# Upstream: tobymao/18xx

`lib/engine.rb` and `lib/engine/` are extracted from the open-source 18xx
engine.

- Source: https://github.com/tobymao/18xx
- Commit: the one in `engine/PIN` (upstream master with Chris' 18OE state, `crericha`, maintainer; moved only by a pull request, see `notes/traps/engine-sync.md` in the workshop). The nightly workflow `engine-upstream-watch` keeps one issue open while upstream is ahead on core or 18OE paths.
- Imported paths: `lib/engine.rb`, `lib/engine/`. Nothing else from the
  upstream `lib/` (assets, auth, mail, ...) is needed to load or run the
  18OE game.

## How this tree is made (#564, #563)

`lib/engine.rb` and `lib/engine/` are **generated, never edited by hand**:

    bin/engine-sync <sha> [--upstream <local clone>]   upstream@sha, minus foreign titles,
                                                       plus engine/local/*.patch, then engine/patches/*.patch
    bin/engine-check                                   offline: every file matches engine/MANIFEST (CI, `changes` job)

- This file is engine/UPSTREAM.md (outside the generated tree, so a sync never wipes it).
- `engine/PIN`: the upstream commit. `engine/MANIFEST`: sha256 of every file of the tree.
- `engine/local/`: load paths only (the `require_all` replacements below); never goes upstream.
- `engine/patches/`: rules and features 18xx lacks and we already have, one patch each, later one upstream PR each.
- Order of a sync: upstream@pin, minus foreign titles, `engine/local/*.patch` (load paths, MRI-only fixes), then
  `engine/patches/*.patch` in file name order. Each patch needs its own spec in `spec/oe/extensions/` (red without it) and
  is shaped like a later upstream pull request (existing ability classes, step/round hooks, game mixins; CLAUDE.md
  rules 11 and 32). No pull request, issue or comment goes to upstream until the owner says so.
- Known deviations of Chris' specs (`spec/engine/upstream`) caused by a patch are listed at the end of this file.
- The wrapper, the bots and the web UI live outside the generated tree (`lib/oe`, `app.rb`, `web/`) and use the engine
  only through its normal interface.

## Removed

- All other game titles: every `lib/engine/game/g_*` directory (and its
  `g_*.rb` stub, where upstream still has one) except `g_18_oe/` and
  `g_18_oe_uk_fr/` (the UK-France scenario variant, kept unmodified because
  the upstream 18OE specs exercise it). Nothing in `g_18_oe/` or the kept core
  files references another title.
- Kept unchanged: the whole core (`round/`, `step/`, `ability/`, `part/`,
  `action/`, `config/`, `helper/`, ...) and the shared top-level files of
  `lib/engine/game/` (`base.rb`, `meta.rb`, shared mixins).

## Modified relative to upstream

Only the loading of code changed; the `RUBY_ENGINE == 'opal'` branches are
left as they were.

- `lib/engine.rb`: `require 'require_all'` / `require_rel 'engine/game'`
  replaced by explicit `Dir[...].sort` requires of `engine/game/*.rb` and the
  `engine/game/g_18_oe/**` and `engine/game/g_18_oe_uk_fr/**` trees (title registry code is unchanged).
- `lib/engine/abilities.rb`: `require_rel 'ability'` replaced by sorted Dir require.
- `lib/engine/tile.rb`: `require_rel 'part'` replaced by sorted Dir require.
- `lib/engine/round/base.rb`: `require_rel '../step'` replaced by sorted Dir require.
- `lib/engine/game/base.rb`: `require_rel` of `../action`, `../round`, `../step`
  replaced by sorted Dir requires (`require 'json'` kept).

All other files are byte-identical to upstream at the commit above. Reason for
all five: the `require_all` gem is not a dependency of this project.

## License

The upstream `LICENSE` file, verbatim:

```
PLEASE NOTE:
The MIT License applies to the Software implementing the game platform on the website 18xx.Games.
All specific game titles appearing within the Software are published on such website
with permission from their respective designers and/or publishers.
The MIT License does not apply to any rights associated with such game titles.

MIT License

Copyright (c) 2021 Tobias Mao

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Known deviations of upstream specs (spec/engine/upstream)

- `stock_round_spec.rb` (six market-move examples), `setup_spec.rb` ('runs the market ...'): the market grid is that of the
  printed board (nine rows, £30 to £550; engine/patches/0013, owner 2026-11-22: "Brett übernehmen"), so the expectations use
  its coordinates.
- `pass_through_routing_spec.rb` (Orient Express detection double): the double answers `connection_data` because
  `orient_express_run?` now excludes sea-only runs (engine/patches/0012).
