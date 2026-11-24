# frozen_string_literal: true

require_relative "../../engine/engine_helper"
require_relative "../../engine/g_18_oe/helpers"

# EXTENSION, red until engine/patches/0023 exists (#596): RB 8.3 and 11.6 let level 3 trains be bought after the first
# OR once the Major RR Phase has begun, "even if there are remaining level 2 trains reserved for purchase". Chris'
# BuyTrain#buyable_trains already drops the 2+2 for an RR whose obligation is fulfilled (non_starter_trains_available?),
# but Engine::Depot offers only the first upcoming train, so a reserved 2+2 nobody may buy any more (its RR became a
# national before buying it, §11.6.4) left the game in Train Phase 2 for good (S2 script games, full run 45435770584).
# Patch: G18OE::Depot#available_upcoming_trains adds the first level 3 train while the exception applies.
describe "G18OE level 3 trains beside reserved 2+2 trains (extension)" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }

  # Every 2+2 but one leaves the Locomotive Works (the last one stays reserved), a regional with its 2+2 is to buy.
  def one_reserved_left!
    holder = game.corporation_by_id("GWR")
    game.depot.upcoming.select { |t| t.name == "2+2" }.drop(2).each { |t| game.buy_train(holder, t, :free) }
    regional = operating_regional!(game, "LNWR", player, trains: ["2+2"], par: 90)
    fund!(game, regional, 1_000)
    game.depot.depot_trains(clear: true)
    regional
  end

  def buyable_names(regional)
    step = operating_round_for!(game).steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::BuyTrain) }
    step.buyable_trains(regional).map(&:name).uniq
  end

  before { allow(game).to receive(:major_phase?).and_return(true) }

  it "offers a level 3 train after the first OR in the Major RR Phase while a reserved 2+2 is left" do
    regional = one_reserved_left!
    game.instance_variable_set(:@first_or_complete, true)
    expect(game.depot.upcoming.count { |t| t.name == "2+2" }).to eq(1)
    expect(buyable_names(regional)).to include("3")
    expect(buyable_names(regional)).not_to include("2+2")
  end

  it "keeps the level 3 trains back in the first OR" do
    regional = one_reserved_left!
    expect(buyable_names(regional)).to eq([])
  end

  it "keeps the level 3 trains back before the Major RR Phase" do
    regional = one_reserved_left!
    game.instance_variable_set(:@first_or_complete, true)
    allow(game).to receive(:major_phase?).and_return(false)
    expect(buyable_names(regional)).to eq([])
  end

  it "still offers the reserved 2+2 to the RR that owes it" do
    one_reserved_left!
    game.instance_variable_set(:@first_or_complete, true)
    owing = start_regional!(game, "PLM", game.players.last, par: 90)
    expect(buyable_names(owing)).to eq(["2+2"])
  end

  it "starts Train Phase 3 when the first level 3 train is bought" do
    regional = one_reserved_left!
    game.instance_variable_set(:@first_or_complete, true)
    three = game.depot.depot_trains.find { |t| t.name == "3" }
    game.buy_train(regional, three, three.price)
    game.phase.buying_train!(regional, three, game.depot)
    expect(game.phase.name).to eq("3")
  end
end
