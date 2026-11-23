# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/view"
require "oe/bot"

# #136: combining non-permanent trains for the Orient Express (RB 12.1).
# The engine offers the type (G18OE::Step::Route#actions: double_head_trains);
# the enumerator builds the concrete combinations, run_routes then routes the
# combined train on an Orient Express run, and the first-time bonus (RB 12.2)
# follows the dividend.
#
# Map: Lille (N31) between two cities O30 and O32 (the network of
# multiple_trains_spec). The Orient Express hexes are stubbed to O30 (origin)
# and O32 (destination), so an Orient Express run here is O30 - Lille - O32:
# three cities, more than one 2+2 can reach, as on the real map a
# Paris-Constantinople run is longer than any single non-permanent train.
RSpec.describe Oe::LegalActions, "double_head_trains (#136)" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:president) { game.players[0] }
  let(:major) { start_major!(game, "LNWR", president) }
  let(:lille) { game.hex_by_id("N31").tile.cities.first }
  let(:west) { game.hex_by_id("O30").tile.cities.first }
  let(:east) { game.hex_by_id("O32").tile.cities.first }

  def lay_tile!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    game.hex_by_id(hex_id).lay(tile)
  end

  def train!(name, entity = major)
    train = game.depot.upcoming.find { |t| t.name == name }
    game.buy_train(entity, train, :free)
    train
  end

  # Puts `entity` first in the OR and walks to its Route step.
  def route_round!(entity = major)
    game.minor_regional_order.delete(entity)
    game.minor_regional_order.unshift(entity)
    round = enter_round!(game, game.operating_round(1))
    round.setup
    5.times do
      break if round.active_step.is_a?(Engine::Game::G18OE::Step::Route)

      act!(game, Engine::Action::Pass.new(round.current_entity))
    end
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::Route)
    round
  end

  def combos(actions = described_class.new(game).call)
    actions.grep(Engine::Action::DoubleHeadTrains).map { |a| a.trains.map(&:name) }
  end

  before do
    major
    lay_tile!("N31", "OE33", 0)
    lay_tile!("O30", "57", 0)
    lay_tile!("O32", "57", 2)
    west.place_token(major, major.next_token, free: true, check_tokenable: false)
    game.graph.clear
    allow(game).to receive(:orient_express_origin_hexes).and_return([west.hex])
    allow(game).to receive(:orient_express_destination_hexes).and_return([east.hex])
  end

  context "with two 2+2 trains and a 3" do
    before do
      train!("2+2")
      train!("2+2")
      train!("3")
    end

    it "offers each distinct combination that can make an Orient Express run (RB 12.1)" do
      route_round!
      expect(game.round.active_step.actions(major)).to include("double_head_trains")
      expect(combos).to contain_exactly(["2+2", "2+2"], ["2+2", "3"], ["2+2", "2+2", "3"])
    end

    it "offers no combination too short for the Orient Express route" do
      route_round!
      allow_any_instance_of(described_class::OrientExpressReach).to receive(:fewest_cities).and_return(5)
      expect(combos).to contain_exactly(["2+2", "3"], ["2+2", "2+2", "3"])
    end

    it "offers nothing when no Orient Express route is found" do
      allow(game).to receive(:orient_express_destination_hexes).and_return([game.hex_by_id("AA82")])
      allow(game).to receive(:orient_express_reachable?).and_return(true)
      route_round!
      expect(game.round.active_step.actions(major)).to include("double_head_trains")
      legal = described_class.new(game)
      expect(combos(legal.call)).to eq([])
      expect(legal.unsupported).to eq([])
    end

    it "measures the cities of the shortest Orient Express route" do
      route_round!
      reach = described_class::OrientExpressReach.new(game, major)
      expect(reach.fewest_cities(game.double_head_candidates(major))).to eq(3)
    end

    it "leaves the game untouched while searching" do
      route_round!
      trains = game.trains.size
      depot = game.depot.trains.size
      described_class.new(game).call
      expect(game.trains.size).to eq(trains)
      expect(game.depot.trains.size).to eq(depot)
      expect(major.trains.map(&:name)).to eq(["2+2", "2+2", "3"])
    end

    it "is accepted; run_routes then runs the combined train on the Orient Express and the bonus follows (RB 12.1, 12.2)" do
      round = route_round!
      combine = described_class.new(game).call.grep(Engine::Action::DoubleHeadTrains)
        .find { |a| a.trains.map(&:name) == ["2+2", "2+2"] }
      act!(game, combine)

      combined = major.trains.find { |t| game.combined_train?(t) }
      expect(combined.name).to eq("4+4C") # Chris' name for a combined train (Step::Route#combined_train!)
      after = described_class.new(game).call
      expect(combos(after)).to eq([])

      run = after.grep(Engine::Action::RunRoutes).first
      oe = run.routes.find { |r| r.train == combined }
      expect(oe).not_to be_nil
      expect(game.orient_express_run?(oe)).to be(true)
      expect(oe.visited_stops).to include(west, lille, east)
      act!(game, run)

      expect(major.trains).not_to include(combined)
      expect(round.orient_express_revenue).to be_positive
      dividend = described_class.new(game).call.grep(Engine::Action::Dividend).first
      act!(game, dividend)
      expect(game.round.active_step).to be_a(Engine::Game::G18OE::Step::OrientExpressBonus)
      expect(described_class.new(game).call.grep(Engine::Action::Choose).map(&:choice)).to eq(%w[cash right])
    end

    it "names the combinations in the prompt, with the train they make" do
      route_round!
      prompt = Oe::View.render(game, viewer: president.id, log: nil)[:prompt]
      expect(prompt[:actions].map { |a| a["type"] }).to include("double_head_trains")
      expect(prompt[:unsupported]).to eq([])
      labels = prompt[:double_head].map { |c| [c[:names], c[:train]] }
      expect(labels).to contain_exactly([["2+2", "2+2"], "4+4"], [["2+2", "3"], "5+2"], [["2+2", "2+2", "3"], "7+4"])
      entry = prompt[:double_head].find { |c| c[:train] == "4+4" }
      expect(entry[:trains].size).to eq(2)
      expect(entry[:label]).to eq("Combine 2+2 and 2+2 into a 4+4 train for the Orient Express")
      expect(prompt[:double_head_note]).to include("cannot be undone")
    end

    it "is not chosen by the bot, which still runs its trains singly (bots on the full rules: v0.3)" do
      route_round!
      action = Oe::Bot.choose(game, rng: Random.new(1), player_id: president.id)
      expect(action).to be_a(Engine::Action::RunRoutes)
    end
  end

  it "never combines a permanent train (RB 12.1)" do
    train!("2+2")
    train!("5")
    train!("3")
    route_round!
    expect(combos).to eq([["2+2", "3"]])
  end

  it "offers nothing to a major with a single non-permanent train" do
    train!("2+2")
    train!("5")
    route_round!
    expect(combos).to eq([])
  end

  it "offers nothing to a regional (only majors make an Orient Express run, RB 12)" do
    regional = start_regional!(game, "KSS", president)
    train!("2+2", regional)
    train!("2+2", regional)
    expect(described_class.new(game).send(:generate_double_head_trains, nil, regional)).to eq([])
  end
end
