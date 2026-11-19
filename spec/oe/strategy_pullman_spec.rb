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
    game.event_pullmans_available!
    game.instance_variable_set(:@pullman_market, 1)
    lnwr.set_cash(600, game.bank)
    round.instance_variable_set(:@entity_index, round.entities.index(lnwr))
    round.instance_variable_set(:@current_operator, lnwr)
    round.steps.each do |s|
      break if s.is_a?(Engine::Game::G18OE::Step::BuyTrain)

      s.pass! unless s.is_a?(Engine::Game::G18OE::Step::ConvertToNational) || s.is_a?(Engine::Step::Bankrupt)
    end
  end

  def legal
    Oe::LegalActions.new(game, limit: 200, rng: Random.new(1)).call
  end

  def choice
    Oe::StrategyPlayer.new(game, rng: Random.new(1)).choose(legal)
  end

  it "offers the Pullman among the legal actions" do
    expect(legal.grep(Engine::Action::Choose).map(&:choice)).to include("pullman_market")
  end

  it "buys it from the Open Market when the train pays it back and cash is left" do
    expect(choice).to be_a(Engine::Action::Choose)
    expect(choice.choice).to eq("pullman_market")
  end

  it "does not buy when the cash buffer is missing" do
    lnwr.set_cash(200, game.bank)
    expect(choice.is_a?(Engine::Action::Choose) && choice.choice.start_with?("pullman_")).to be(false)
  end

  it "does not buy when the highest train is too low to pay it back" do
    game.depot.remove_train(lnwr.trains.first)
    lnwr.trains.clear
    with_trains!(game, lnwr, "2+2")
    expect(choice.is_a?(Engine::Action::Choose) && choice.choice.start_with?("pullman_")).to be(false)
  end

  it "never buys a second one" do
    game.receive_pullman!(lnwr)
    expect(choice.is_a?(Engine::Action::Choose) && choice.choice.start_with?("pullman_")).to be(false)
  end
end
