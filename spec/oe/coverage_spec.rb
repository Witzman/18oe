# frozen_string_literal: true

require "spec_helper"
require "oe/view"
require "oe/coverage"
require "oe/strategy_player"
require "oe/legal_actions"
require_relative "../engine/g_18_oe/helpers"

# #130: meta.coverage says whether the state lies within the verified slice (S1).
RSpec.describe "Oe::View meta.coverage (#130)" do
  include G18OESpecHelpers

  def coverage(game)
    Oe::View.render(game, actions: false)[:meta][:coverage]
  end

  let(:game) { new_game(%w[a b c d]) }

  it "is verified at the start of a game" do
    expect(coverage(game)).to eq(slice: "S1", verified: true, reason: nil)
  end

  it "stays verified through the first actions of a strategy game" do
    rng = Random.new(1)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    120.times do
      break if game.finished

      actions = Oe::LegalActions.new(game, limit: 8, rng: rng).call
      game.process_action(strategist.choose(actions) || actions.sample(random: rng))
      expect(coverage(game)).to include(verified: true)
    end
  end

  it "is false once the major phase begins" do
    allow(game).to receive(:major_phase?).and_return(true)
    expect(coverage(game)).to eq(slice: "S1", verified: false, reason: "major_phase")
  end

  it "is false in a train phase outside the slice" do
    allow(game.phase).to receive(:name).and_return("3")
    expect(coverage(game)).to include(verified: false, reason: "train_phase:3")
  end

  it "is false in a step outside the slice list" do
    step = Engine::Game::G18OE::Step::Consolidate.allocate
    allow(game.round).to receive(:active_step).and_return(step)
    expect(Oe::Coverage.for(game)).to include(verified: false, reason: "step:Consolidate")
  end

  it "is false in a round outside the slice list" do
    allow(game).to receive(:round).and_return(game.new_consolidation_round)
    expect(Oe::Coverage.for(game)).to include(verified: false, reason: "round:Consolidation")
  end
end
