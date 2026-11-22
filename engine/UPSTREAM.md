# Upstream: tobymao/18xx

`lib/engine.rb` and `lib/engine/` are extracted from the open-source 18xx
engine.

- Source: https://github.com/tobymao/18xx
- Commit: `06b3f0b37bddbf587a5e39424a3511b5e4674c47` (06b3f0b37), dated 2026-11-09 02:12:32 -0500
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
- Until Task 2 of #563 the tree is still the old hand-modified import (own changes inside, see
  `notes/rueckport-differenz/diff-Kern.md` in the workshop); PIN/MANIFEST then only freeze that state so no
  further hand edit slips in. `bin/engine-sync 06b3f0b37` reproduces the loading patch exactly; every other
  difference to it is an own change that Task 2 replaces with upstream master.

## Removed

- All other game titles: every `lib/engine/game/g_*` directory and its
  `g_*.rb` stub except `g_18_oe/`, `g_18_oe.rb`, `g_18_oe_uk_fr/` and
  `g_18_oe_uk_fr.rb` (the UK-France scenario variant, kept unmodified because
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

- `right_of_way_spec.rb` 'finds Barcelona a yellow route to the town next to it': expects side 1 connectable (true) instead of
  false because patch 0003 puts Palma (AB27) in the Spain zone (owner, who built the map, 2026-11-22: "Palma ist Spanien").
