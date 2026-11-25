# frozen_string_literal: true

# #604: a live move must be stored as 18xx.games stores it: the action hash *after* the step ran
# (assets/app/view/game/actionable.rb: process_action(action, add_auto_actions: true), then action.to_h).
# The 18OE Track step fills in `extra_cost` (the cross-water fee, §11.1.6) during process_action and takes it
# from the log while loading; a hash written before that carries no fee and the replay diverges.
require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/live"

describe "Oe::Live: a live lay_tile with a cross-water fee replays to the same state (#604)" do
  include G18OESpecHelpers

  # Scene of cross_water_spec: LNWR holds Königsberg with track to the Baltic port arrow; a tile laid into the
  # unconnected public arrow of Danzig (K60) crosses one sea zone: £10 (§11.1.3, §11.1.6).
  def scene
    game = new_game
    game.minor_merged
    lnwr = start_major!(game, "LNWR", game.players.first)
    lay_tile!(game, "J63", "57", rotation: 1)
    place_token!(game, "J63", lnwr)
    game.bank.spend(500 - lnwr.cash, lnwr)
    round = enter_round!(game, game.operating_round(1))
    round.entities = [lnwr]
    round.instance_variable_set(:@current_operator, lnwr)
    round.instance_variable_set(:@entity_index, 0)
    [game, lnwr]
  end

  def lay_into_danzig(game, lnwr)
    tile = game.tiles.find { |t| t.name == "3" && !t.hex }
    hex = game.hex_by_id("K60")
    step = game.round.steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::Track) }
    rotation = step.legal_tile_rotations(lnwr, hex, tile).find do |r|
      tile.rotate!(r)
      tile.exits.include?(3)
    end
    Engine::Action::LayTile.new(lnwr, tile: tile, hex: hex, rotation: rotation)
  end

  it "stores the fee with the action and the replay pays it as well" do
    live, live_lnwr = scene
    Oe::Live.process(live, lay_into_danzig(live, live_lnwr))
    expect(live.exception).to be_nil
    expect(live_lnwr.cash).to eq(490)
    stored = live.raw_actions.last
    expect(stored["extra_cost"]).to eq(10)

    # Replay: the same scene, the stored hash processed while loading, as Game.new(actions: ...) does.
    replay, replay_lnwr = scene
    replay.instance_variable_set(:@loading, true)
    replay.process_action(JSON.parse(JSON.generate(stored)))
    replay.instance_variable_set(:@loading, false)
    expect(replay.exception).to be_nil
    expect(replay_lnwr.cash).to eq(live_lnwr.cash)
    expect(replay.hex_by_id("K60").tile.name).to eq("3")
  end
end
