# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/legal_actions"
require "oe/strategy_player"
require "oe/invariants"
require "json"
require_relative "../support/view_checks"

# #438 (P10 of #437): a short seed game in the fast stage. The strategy player plays seed 1 with four players
# through the auction (cheap, ~2 s) and then SMOKE_ACTIONS actions of operating and stock rounds; after each of
# those the engine must have taken the action, the invariants (lib/oe/invariants.rb) must hold, and the view must
# render, survive JSON and carry the step's texts. No expectation depends on the course of the game: a rule change
# that alters the moves keeps this green as long as nothing breaks. Whole games and the expectations on their
# course stay in the full stage (:game_flow). Budget: well under 60 s on a CI runner.
RSpec.describe "Seed smoke (#438)", :seed_smoke do
  include OeViewChecks

  SMOKE_SEED = 1
  SMOKE_ACTIONS = 300
  # Actions before the first operating round may take at most this many (seed 1 needs ~2400).
  SMOKE_PRELUDE_CAP = 5000

  before(:all) do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: SMOKE_SEED, seed: SMOKE_SEED)
    rng = Random.new(SMOKE_SEED)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    @found = []
    @checked = 0
    @rounds = Hash.new(0)
    count = 0
    until game.finished || @checked >= SMOKE_ACTIONS || (@checked.zero? && count >= SMOKE_PRELUDE_CAP)
      acts = Oe::LegalActions.new(game, limit: 8, rng: rng).call
      if acts.empty?
        @found << "action #{count}: no legal action in #{game.round.active_step.class.name}"
        break
      end

      action = strategist.choose(acts) || acts.sample(random: rng)
      game.process_action(action)
      count += 1
      if game.exception
        @found << "action #{count}: engine rejected #{action.to_h}: #{game.exception.message}"
        break
      end
      next unless @checked.positive? || game.round.operating?

      @checked += 1
      @rounds[game.round.class.name.split("::").last] += 1
      smoke_check(game, count)
    end
    @game = game
  end

  def smoke_check(game, count)
    Oe::Invariants.failures(Oe::Invariants.run(game)).each { |v| @found << "action #{count}: #{v}" }
    return if game.finished

    view = Oe::View.render(game, viewer: game.active_players.first&.id, log: nil)
    JSON.parse(JSON.generate(view))
    prompt_text_errors(game, view).each { |e| @found << "action #{count}: #{e}" }
  rescue StandardError => e
    @found << "action #{count}: #{e.class} #{e.message.lines.first}"
  end

  it "reaches an operating round and checks #{SMOKE_ACTIONS} actions after it (or the game's end)" do
    expect(@checked == SMOKE_ACTIONS || @game.finished).to be(true), "checked #{@checked} actions, rounds #{@rounds}"
  end

  it "takes every action, holds the invariants and renders the view after each" do
    expect(@found.first(5)).to eq([])
  end
end
