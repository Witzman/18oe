# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/legal_actions"
require "oe/strategy_player"
require "json"

# #91: bids are described as ranges instead of thousands of actions. The ranges
# must describe exactly the bids the full enumeration offers.
RSpec.describe "prompt ranges (#91)" do
  def expand(ranges)
    ranges.flat_map do |r|
      (r[:min]..r[:max]).step(r[:step]).map { |price| [r[:entity], r[:company], price] }
    end.sort
  end

  def bids(actions)
    actions.select { |a| a.is_a?(Engine::Action::Bid) }.map { |a| [a.entity.id, a.company.id, a.price] }.sort
  end

  it "expand to exactly the bids of the full enumeration, along a played auction" do
    game = Engine::Game::G18OE::Game.new(%w[A B C D], id: 1, seed: 1)
    rng = Random.new(1)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    checked = 0
    400.times do |i|
      break if game.finished

      full = Oe::LegalActions.new(game, limit: nil).call
      compact = Oe::LegalActions.new(game, limit: nil, compact: true)
      rest = compact.call
      expect(expand(compact.ranges)).to eq(bids(full)), "state #{i}"
      expect(rest.none? { |a| a.is_a?(Engine::Action::Bid) }).to be(true)
      checked += 1 unless compact.ranges.empty?
      game.process_action(strategist.choose(Oe::LegalActions.new(game, limit: 12, rng: rng).call))
    end
    expect(checked).to be > 20
  end

  it "keeps the state small: the first auction prompt is a few KB, not hundreds" do
    game = Engine::Game::G18OE::Game.new(%w[A B C D], id: 3, seed: 3)
    view = Oe::View.render(game, viewer: game.active_players.first.id, log: nil)
    expect(view[:prompt][:ranges]).not_to be_empty
    expect(view[:prompt][:actions].none? { |a| a["type"] == "bid" || a[:type] == "bid" }).to be(true)
    expect(JSON.generate(view).bytesize).to be < 60_000
  end
end
