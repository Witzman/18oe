# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/view"
require "oe/strategy_player"

# #127: a depot train is a double-sided card (RB 11.6): 3 or 3+3, 4 or 4+4, 5 or
# 5+5, 6 or 6+6, 7+7 or 4D, 8+8 or 5D, each side at its own price. The enumerator
# offers one BuyTrain per side, the engine accepts each and the bought train
# carries the side's name.
RSpec.describe Oe::LegalActions, "train variants" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:buyer) { start_major!(game, "LNWR", game.players[0]) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::BuyTrain) }
  let(:round) do
    buyer
    game.fulfill_train_obligation!(buyer)
    # Make `target` the next train of the depot: drop everything before it.
    game.depot.upcoming.dup.each do |t|
      break if t.name == target

      game.depot.remove_train(t)
    end
    game.instance_variable_set(:@first_or_complete, true)
    enter_round!(game, game.operating_round(1))
  end
  let(:target) { "3" }
  let(:cash) { 2000 }

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    allow(game).to receive(:level8_train_available?).and_return(true)
    round
    fund!(game, buyer, cash - buyer.cash)
    allow(step).to receive(:current_entity).and_return(buyer)
  end

  def offers
    described_class.new(game).send(:generate_buy_train, step, buyer)
      .select { |a| a.train == game.depot.depot_trains.first }
      .to_h { |a| [a.variant, a.price] }
  end

  {
    "3" => { "3" => 200, "3+3" => 225 },
    "4" => { "4" => 300, "4+4" => 350 },
    "5" => { "5" => 400, "5+5" => 475 },
    "6" => { "6" => 525, "6+6" => 600 },
    "7+7" => { "7+7" => 750, "4D" => 850 },
    "8+8" => { "8+8" => 900, "5D" => 1000 },
  }.each do |name, expected|
    context "level #{name}" do
      let(:target) { name }

      it "offers every side at its price, and the engine buys each" do
        expect(game.depot.depot_trains.first.name).to eq(name)
        expect(offers).to eq(expected)

        expected.each do |variant, price|
          action = described_class.new(game).send(:generate_buy_train, step, buyer)
                    .find { |a| a.variant == variant && a.train == game.depot.depot_trains.first }
          expect(action.price).to eq(price)
          train = action.train
          cash_before = buyer.cash
          expect { step.process_buy_train(action) }.not_to raise_error
          expect(train.name).to eq(variant)
          expect(train.owner).to eq(buyer)
          expect(buyer.cash).to eq(cash_before - price)
          # next side: give the train back so each variant is tried on a clean state
          buyer.trains.delete(train)
          game.depot.reclaim_train(train)
          train.owner = game.depot
          fund!(game, buyer, cash - buyer.cash)
        end
      end
    end
  end

  it "offers only the sides the treasury can pay" do
    buyer.spend(buyer.cash - 210, game.bank)
    # Chris' Step::Train lets the president chip in for the cheapest depot train, so he is drained too (#356).
    buyer.owner.spend(buyer.owner.cash, game.bank) if buyer.owner.cash.positive?

    expect(offers).to eq("3" => 200)
  end

  it "offers the dearer side once the treasury covers it" do
    buyer.spend(buyer.cash - 225, game.bank)

    expect(offers).to eq("3" => 200, "3+3" => 225)
  end

  it "shows the sides with price and reach in the view of a depot train" do
    train = game.depot.depot_trains.first
    view = Oe::View.send(:train, train)

    expect(view[:variants].map { |v| [v[:name], v[:price]] }).to eq([["3", 200], ["3+3", 225]])
    expect(view[:variants].first[:distance]).not_to be_empty
  end
end

RSpec.describe Oe::StrategyPlayer, "train variants (#127)" do
  include G18OESpecHelpers

  it "keeps buying the base side of a double-sided train until the bots learn the full rules" do
    game = new_game
    corp = start_major!(game, "LNWR", game.players[0])
    train = game.depot.upcoming.find { |t| t.name == "3" }
    fund!(game, corp, 1000 - corp.cash)
    actions = [Engine::Action::BuyTrain.new(corp, train: train, price: 225, variant: "3+3"),
               Engine::Action::BuyTrain.new(corp, train: train, price: 200, variant: "3")]

    pick = described_class.new(game, rng: Random.new(1)).send(:pick_buy_train, actions, {})

    expect(pick.variant).to eq("3")
  end
end
