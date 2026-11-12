# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/legal_actions"
require "oe/strategy_player"
require "json"

# #119: the run each train drove, per corporation, in the view. Checked against a
# played game: the train revenues add up, the hexes exist on the board, and the
# paths form a connected sequence.
RSpec.describe "Oe::View last_run routes (#119)" do
  it "describes every train's run consistently in a played game" do
    game = Engine::Game::G18OE::Game.new(%w[A B C D], id: 1, seed: 1)
    rng = Random.new(1)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    seen = 0
    runs = []
    2600.times do |i|
      break if game.finished

      acts = Oe::LegalActions.new(game, limit: 12, rng: rng).call
      break if acts.empty?

      game.process_action(strategist.choose(acts))
      next unless (i % 50).zero?

      view = JSON.parse(JSON.generate(Oe::View.render(game, log: nil, actions: false)))
      view["corporations"].each { |c| runs << c["last_run"] if c["last_run"] && c["last_run"]["routes"].any? }
    end

    expect(runs).not_to be_empty
    runs.each do |run|
      run["routes"].each do |r|
        expect(r.keys.sort).to eq(%w[hexes name revenue segments stops train])
        expect(r["hexes"]).to all(satisfy { |id| game.hex_by_id(id) })
        expect(r["segments"].map { |s| s["hex"] }.chunk(&:itself).map(&:first)).to eq(r["hexes"].uniq) if r["segments"].any?
        expect(r["stops"].sum { |s| s["revenue"] }).to eq(r["revenue"])
        seen += 1
      end
      expect(run["routes"].sum { |r| r["revenue"] }).to eq(run["revenue"])
    end
    expect(seen).to be > 0
  end

  it "has no routes for a corporation that never ran" do
    game = Engine::Game::G18OE::Game.new(%w[A B C D], id: 1, seed: 1)
    view = Oe::View.render(game, log: nil, actions: false)
    expect(view[:corporations].map { |c| c[:last_run] }.compact).to eq([])
  end
end
