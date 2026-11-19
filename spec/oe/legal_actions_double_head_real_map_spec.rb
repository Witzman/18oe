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

  # Shortest land path from `from` to `to`.
  def land_path(from, to)
    prev = { from => nil }
    queue = [from]
    until queue.empty?
      hex = queue.shift
      break if hex == to

      hex.neighbors.each_value do |other|
        next if prev.key?(other) || other.tile.color != :white

        prev[other] = hex
        queue << other
      end
    end
    path = []
    hex = to
    while hex
      path.unshift(hex)
      hex = prev[hex]
    end
    path
  end

  def edge_between(hex, other)
    hex.neighbors.find { |_edge, n| n == other }.first
  end

  # Lays on `hex` the plainest supply tile with the printed stops of the hex whose exits include
  # `edges` (rotated to fit); a stop's two exits must meet in one stop.
  def lay_through!(hex, edges)
    stops = [hex.tile.cities.size, hex.tile.towns.size]
    candidates = game.tiles.select do |t|
      t.hex.nil? && t.color == :yellow && [t.cities.size, t.towns.size] == stops
    end
    candidates.sort_by { |t| t.exits.size }.each do |tile|
      6.times do |rotation|
        tile.rotate!(rotation)
        next unless (edges - tile.exits).empty?
        next unless connects?(tile, edges)

        game.update_tile_lists(tile, hex.tile)
        hex.lay(tile)
        return tile
      end
    end
    raise "no tile for #{hex.id} #{edges.inspect}"
  end

  def connects?(tile, edges)
    return true if tile.cities.empty? && tile.towns.empty? && tile.paths.any? { |p| (edges - p.exits).empty? }

    nodes = edges.map { |e| tile.paths.select { |p| p.exits.include?(e) }.flat_map(&:nodes) }
    nodes.reduce(:&).any? || (tile.cities.empty? && tile.towns.empty?)
  end

  def lay_chain!(path)
    path.each_with_index do |hex, i|
      edges = []
      edges << edge_between(hex, path[i - 1]) if i.positive?
      edges << edge_between(hex, path[i + 1]) if i < path.size - 1
      lay_through!(hex, edges)
    end
    game.graph.clear
  end

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
    @path = land_path(paris, constantinople)
    lay_chain!(@path)
    # Paris has three cities; the station goes into the one the track to Q32 leaves from.
    out = edge_between(paris, @path[1])
    city = paris.tile.cities.find { |c| c.paths.any? { |pa| pa.exits.include?(out) } }
    city.place_token(major, major.next_token, free: true, check_tokenable: false)
    game.graph.clear
    with_trains!(game, major, "2+2", "2+2")
  end

  it "has an Orient Express origin and destination on the real map" do
    expect(game.orient_express_origin_hexes).to include(paris)
    expect(game.orient_express_destination_hexes).to include(constantinople)
    expect(game.orient_express_reachable?(major)).to be(true)
  end

  it "offers the combination, accepts it, runs Paris - Constantinople and shows the bonus step" do
    round = route_round!
    expect(game.round.active_step.actions(major)).to include("double_head_trains")
    expect(combos).to eq([["2+2", "2+2"]])

    combine = described_class.new(game).call.grep(Engine::Action::DoubleHeadTrains).first
    act!(game, combine)
    combined = major.trains.find { |t| game.combined_train?(t) }
    expect(combined.name).to eq("4+4")

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
