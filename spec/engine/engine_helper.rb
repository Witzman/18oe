# frozen_string_literal: true

# Shared setup for the engine specs. Deliberately independent of spec_helper
# (no Sinatra app, no rack-test): the engine specs only need the engine.
# The upstream engine specs use the global `describe` DSL, so monkey patching
# is left enabled here.

# The engine logs every action at DEBUG unless told otherwise (3 = ERROR).
ENV["ENGINE_LOG_LEVEL"] ||= "3"

require "engine"
require "rspec"

# Bot games in the specs are capped (#314): a bot plays ~2900 actions/min since it founds regionals and
# majors, a whole game takes ~7 min. GAME_CAP actions cover set-up, auctions, concessions, stock and
# operating rounds. One whole game is the :full_game example(s), run in the full stage with
# OE_FULL_GAME=1 (.github/workflows/full.yml, job full-game); GAME_CAP is then lifted.
FULL_GAME = ENV["OE_FULL_GAME"] == "1"
# OE_GAME_CAP (#335) overrides both caps (GAME_CAP and STRATEGY_CAP) for a run without OE_FULL_GAME.
CAP_OVERRIDE = ENV["OE_GAME_CAP"].to_s.empty? ? nil : ENV["OE_GAME_CAP"].to_i
GAME_CAP = FULL_GAME ? 30_000 : (CAP_OVERRIDE || 1500)
# #335: 3200 (was 5000) per pull request: the auction costs little (~5 s per 3000 actions), the operating
# rounds after it dominate (upgrades, route search), and a CI round must stay near 5 min; the full stage
# plays to the end. The strategy player (view specs) spends ~2400 actions in the auction before the concession round and
# reaches operating rounds at ~2400 and consolidation at ~3800 (seed 1), cheaply (~5 s per 3000).
STRATEGY_CAP = FULL_GAME ? 30_000 : (CAP_OVERRIDE || 3200)

RSpec.configure do |config|
  config.filter_run_excluding full_game: true unless FULL_GAME
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
