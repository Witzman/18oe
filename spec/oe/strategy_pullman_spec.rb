# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/strategy_player"

# #55 part 3: the bot buys a Pullman when it pays back within a few ORs (rule 7: simple local rule).
RSpec.describe "Strategy player buying a Pullman (#55)" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let!(:lnwr) { start_major!(game, "LNWR", game.players[0]) }
  let(:round) { at_phase!(game, "4") && operating_round_for!(game, 1) }
  let(:cars) { with_trains!(game, lnwr, "3") }

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    cars
    game.fulfill_train_obligation!(lnwr)
    game.instance_variable_set(:@first_or_complete, true)
    allow_any_instance_of(Oe::StrategyPlayer).to receive(:landing_seas).and_return([]) # no port authority here
    lnwr.set_cash(600, game.bank)
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

  # A Pullman is a depot train now (Chris' engine): a BuyTrain with the variant "Pullman".
  def pullman_buy?(action)
    action.is_a?(Engine::Action::BuyTrain) && game.pullman?(action.train)
  end

  it "offers the Pullman among the legal actions" do
    expect(legal.any? { |a| pullman_buy?(a) }).to be(true)
  end

  it "buys it when the train pays it back and cash is left" do
    expect(pullman_buy?(choice)).to be(true)
    expect(choice.price).to eq(150)
  end

  it "does not buy when the cash buffer is missing" do
    lnwr.set_cash(200, game.bank)
    expect(pullman_buy?(choice)).to be(false)
  end

  it "does not buy when the highest train is too low to pay it back" do
    game.depot.remove_train(lnwr.trains.first)
    lnwr.trains.clear
    with_trains!(game, lnwr, "2+2")
    expect(pullman_buy?(choice)).to be(false)
  end

  it "never buys a second one" do
    pullman = game.depot.depot_trains.find { |train| game.pullman?(train) }
    game.buy_train(lnwr, pullman, :free)
    expect(pullman_buy?(choice)).to be(false)
  end
end
