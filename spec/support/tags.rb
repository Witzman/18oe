# frozen_string_literal: true

# The RSpec tags of this suite (#365) -- the one place that defines them. Required by spec/spec_helper.rb
# and spec/engine/engine_helper.rb, so every spec file knows them.
#
#   :game_flow  the example plays a seed game or a recorded log (strategy/bot game, fixture catalog,
#               replay). It depends on the course of the game and breaks after a legitimate rule or
#               parameter change. Slow; belongs to the milestone stage, not to the fast one.
#   :full_game  a whole game to its end (~7 min). Runs only on request: OE_FULL_GAME=1 / --tag full_game
#               (the exclusion is in spec/engine/engine_helper.rb).
#   :browser    needs a browser. No RSpec example uses it yet (the browser tests are web/test/*-browser.test.ts);
#               the tag is reserved so the stages can use one vocabulary.
#
# A tag only labels. Without --tag/--tag ~x filters every example runs as before: a stage picks its set
# with `--tag game_flow` / `--tag ~game_flow`. Untagged = fast: state built by code, no game played.
# New tag? Add it to KNOWN here; spec/tags_spec.rb fails on any other bare tag, so that a typo such as
# :gameflow cannot silently move an example from one stage to the other.
module OeSpecTags
  STAGE_TAGS = %i[game_flow full_game browser].freeze
  # Other metadata used in the suite (not stage tags).
  OTHER = %i[].freeze
  KNOWN = (STAGE_TAGS + OTHER).freeze
end
