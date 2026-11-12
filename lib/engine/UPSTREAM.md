# Upstream: tobymao/18xx

`lib/engine.rb` and `lib/engine/` are extracted from the open-source 18xx
engine.

- Source: https://github.com/tobymao/18xx
- Commit: `06b3f0b37bddbf587a5e39424a3511b5e4674c47` (06b3f0b37), dated 2026-11-09 02:12:32 -0500
- Imported paths: `lib/engine.rb`, `lib/engine/`. Nothing else from the
  upstream `lib/` (assets, auth, mail, ...) is needed to load or run the
  18OE game.

## Removed

- All other game titles: every `lib/engine/game/g_*` directory and its
  `g_*.rb` stub except `g_18_oe/` and `g_18_oe.rb`, including the
  `g_18_oe_uk_fr` variant. Nothing in `g_18_oe/` or the kept core files
  references another title.
- Kept unchanged: the whole core (`round/`, `step/`, `ability/`, `part/`,
  `action/`, `config/`, `helper/`, ...) and the shared top-level files of
  `lib/engine/game/` (`base.rb`, `meta.rb`, shared mixins).

## Modified relative to upstream

Only the loading of code changed; the `RUBY_ENGINE == 'opal'` branches are
left as they were.

- `lib/engine.rb`: `require 'require_all'` / `require_rel 'engine/game'`
  replaced by explicit `Dir[...].sort` requires of `engine/game/*.rb` and the
  `engine/game/g_18_oe/**` tree (title registry code is unchanged).
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
