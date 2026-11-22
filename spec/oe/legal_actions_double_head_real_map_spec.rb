# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/view"

# #411: the combination of non-permanent trains (#136, RB 12.1) on the REAL map, no stub of the
# Orient Express hexes (legal_actions_double_head_spec.rb stubs them to O30/O32). The state is
# built with the scenario helpers: a major with a station in Paris (Q30), a chain of yellow
# tiles over the shortest land path Paris - Constantinople (AA82), two 2+2 trains. No seed game.
RSpec.describe Oe::LegalActions, "double_head_trains on the real map (#411)" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:president) { game.players[0] }
  let(:major) { start_major!(game, "LNWR", president) }
  let(:paris) { game.hex_by_id("Q30") }
  let(:constantinople) { game.hex_by_id("AA82") }

  def combos(actions = described_class.new(game).call)
    actions.grep(Engine::Action::DoubleHeadTrains).map { |a| a.trains.map(&:name) }
  end

  before do
    major
    # Paris has three cities; the station goes into the one the track to Q32 leaves from (helpers.rb).
    @path = paris_constantinople_chain!(game, major)
    with_trains!(game, major, "2+2", "2+2")
  end

  it "has an Orient Express origin and destination on the real map" do
    expect(game.orient_express_origin_hexes).to include(paris)
    expect(game.orient_express_destination_hexes).to include(constantinople)
    expect(game.orient_express_reachable?(major)).to be(true)
  end

  it "offers the combination, accepts it, runs Paris - Constantinople and shows the bonus step" do
    round = route_round!(game, major)
    expect(game.round.active_step.actions(major)).to include("double_head_trains")
    expect(combos).to eq([["2+2", "2+2"]])

    combine = described_class.new(game).call.grep(Engine::Action::DoubleHeadTrains).first
    act!(game, combine)
    combined = major.trains.find { |t| game.combined_train?(t) }
    expect(combined.name).to eq("4+4C") # Chris' name for a combined train

    after = described_class.new(game).call
    run = after.grep(Engine::Action::RunRoutes).first
    oe = run.routes.find { |r| r.train == combined }
    expect(oe).not_to be_nil
    expect(game.orient_express_run?(oe)).to be(true)
    hexes = oe.visited_stops.map(&:hex)
    expect(hexes).to include(paris, constantinople)
    act!(game, run)

    expect(round.orient_express_revenue).to be_positive
    act!(game, described_class.new(game).call.grep(Engine::Action::Dividend).first)
    expect(game.round.active_step).to be_a(Engine::Game::G18OE::Step::OrientExpressBonus)
  end
end
