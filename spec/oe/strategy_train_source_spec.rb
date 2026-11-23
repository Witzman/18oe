# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/strategy_player"

# #428: two bots must not sell each other trains back and forth. The strategy player buys from the
# depot when it can and takes a train of another corporation only at the lowest price offered.
RSpec.describe "Strategy player buying a train from another corporation (#428)" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let!(:lnwr) { start_major!(game, "LNWR", game.players[0]) }
  let!(:gwr) { start_major!(game, "GWR", game.players[1]) }
  let(:round) { at_phase!(game, "4") && operating_round_for!(game, 1) }

  before do
    with_trains!(game, gwr, "3")
    allow(game).to receive(:major_phase?).and_return(true)
    game.fulfill_train_obligation!(lnwr)
    game.instance_variable_set(:@first_or_complete, true)
    lnwr.set_cash(900, game.bank)
    round.instance_variable_set(:@entity_index, round.entities.index(lnwr))
    round.instance_variable_set(:@current_operator, lnwr)
    round.steps.each do |s|
      break if s.is_a?(Engine::Game::G18OE::Step::BuyTrain)

      s.pass! unless s.is_a?(Engine::Game::G18OE::Step::FormNational) || s.is_a?(Engine::Step::Bankrupt)
    end
  end

  def legal
    Oe::LegalActions.new(game, limit: 200, rng: Random.new(1)).call
  end

  def choice
    Oe::StrategyPlayer.new(game, rng: Random.new(1)).choose(legal)
  end

  it "offers the other corporation's train as well as the depot's" do
    owners = legal.grep(Engine::Action::BuyTrain).map { |a| a.train.owner }.uniq
    expect(owners).to include(gwr, game.depot)
  end

  it "prefers the depot train to one of another corporation" do
    expect(choice.train.owner).to eq(game.depot)
  end
end
