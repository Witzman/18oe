# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/view"

# #359 (SC5): the route search (Oe::RouteSearch, used by RoutePicker, the bots
# and the strategy player) finds routes with a sea crossing (§11.3.4): at a node
# with a usable port the walk jumps to any other usable port node, and the jump
# becomes a route chain without track (#357). The scenes are those of the
# sea crossing spec (PB 4.4, 4.5).
RSpec.describe Oe::RouteSearch, "sea crossings" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:dsj) { game.corporation_by_id("DSJ") }
  let(:bjv) { game.corporation_by_id("BJV") }
  let(:corp) { game.corporation_by_id("LNWR") }

  def lay_tile!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    game.hex_by_id(hex_id).lay(tile)
  end

  def node(hex_id)
    tile = game.hex_by_id(hex_id).tile
    tile.cities.first || tile.offboards.first
  end

  def token!(hex_id, corporation)
    node(hex_id).place_token(corporation, corporation.next_token, free: true, check_tokenable: false)
  end

  def train!(corporation, name)
    train = game.trains.find { |t| t.name == name && !t.owner.is_a?(Engine::Corporation) }
    game.buy_train(corporation, train, :free)
    train
  end

  def search(corporation, *trains)
    game.graph.clear
    routes, = described_class.new(game).path(trains, corporation)
    routes
  end

  def stop_hexes(route)
    route.visited_stops.map { |stop| stop.hex.id }.sort
  end

  def sea?(route)
    game.sea_legs(route).any?
  end

  describe "BJV Christiania to Kobenhavn (PB 4.4)" do
    before { token!("C48", bjv) }

    it "finds the crossing from the Christiania offshore port, with no track at all" do
      train = train!(bjv, "3")
      routes = search(bjv, train)[train]

      crossing = routes.find { |route| stop_hexes(route) == %w[C48 I50] }
      expect(crossing).not_to be_nil
      expect(sea?(crossing)).to be(true)
      expect(game.sea_distance(crossing)).to eq(0) # one zone, the Christiania token takes it
      expect(crossing.revenue).to be_positive
    end

    it "keeps the crossing through a run routes action written out and read back (replay)" do
      train = train!(bjv, "3")
      route = search(bjv, train)[train].find { |r| stop_hexes(r) == %w[C48 I50] }
      revenue = route.revenue
      action = Engine::Action::RunRoutes.new(bjv, routes: [route])

      replayed = Engine::Action::Base.action_from_h(action.to_h, game).routes.first

      expect(replayed.connection_hexes).to eq(route.connection_hexes)
      expect(replayed.revenue).to eq(revenue)
    end

    it "is picked by the RoutePicker, the route the bots and the UI take" do
      train!(bjv, "3")
      game.graph.clear
      routes = Oe::LegalActions::RoutePicker.new(game, bjv).call

      expect(routes.size).to eq(1)
      expect(routes.first.revenue).to be_positive
      expect(stop_hexes(routes.first)).to include("C48")
    end
  end

  describe "the run in the view" do
    before { token!("C48", bjv) }

    it "lists only real hexes for a run with a crossing (the crossing itself is #362)" do
      train = train!(bjv, "3")
      route = search(bjv, train)[train].find { |r| stop_hexes(r) == %w[C48 I50] }
      route.routes = [route]

      expect(route.connection_hexes.flatten.map { |c| c["hexes"] }.flatten).to include("crossing")
      expect(Oe::RunDetail.detail(game, route)[:hexes]).to match_array(%w[C48 I50])
    end

    # #436: as spec/oe/view_routes_spec.rb checks for a played game, the segments of a run follow its hexes, also
    # over a crossing (a chain without track): the crossing's port hexes stand in the segments, without exits.
    it "keeps segments and hexes in step for runs with a crossing, before, after or without track" do
      lay_tile!("AA20", "5", 4)
      lay_tile!("AB27", "5", 1)
      token!("AA20", corp)
      train = train!(corp, "5")
      routes = search(corp, train)[train].select { |route| sea?(route) }
      routes << search(bjv, train!(bjv, "3")).values.flatten.find { |r| stop_hexes(r) == %w[C48 I50] }
      expect(routes.size).to be > 2

      routes.each do |route|
        route.routes = [route]
        detail = Oe::RunDetail.detail(game, route)

        expect(detail[:segments]).not_to be_empty
        expect(detail[:segments].map { |s| s[:hex] }.chunk(&:itself).map(&:first)).to eq(detail[:hexes].uniq)
      end
    end
  end

  # #362 (SC8): the view names the sea stretches of a run: per crossing its ports, zones and what counts against
  # the city limit after the reductions, per ferry its distance, and the route's distance_str (#356).
  describe "the sea stretches in the view (#362)" do
    def detail_of(route)
      route.routes = [route]
      Oe::RunDetail.detail(game, route)
    end

    it "lists the DSJ crossing Malmo to Kobenhavn with its zones and the port token's reduction" do
      lay_tile!("I52", "57", 0)
      token!("I52", dsj)
      train = train!(dsj, "3")
      route = search(dsj, train)[train].find { |r| stop_hexes(r) == %w[I50 I52] }
      detail = detail_of(route)

      expect(detail[:sea].size).to eq(1)
      crossing = detail[:sea].first
      expect([crossing[:from], crossing[:to]].sort).to eq(%w[I50 I52])
      expect(crossing[:zones]).to eq(2)
      # Chris' engine takes the port token's reduction in game.sea_distance; RunDetail does not split it per stretch
      expect(game.sea_distance(route)).to eq(1)
      expect(crossing.keys).to include(:from_exit, :to_exit)
      expect(detail[:ferries]).to eq([])
      expect(detail[:distance_str]).to eq(route.distance_str)
    end

    it "lists a ferry with its distance and counts crossing and ferry as sea_units does" do
      lay_tile!("AA20", "5", 4)
      lay_tile!("AB27", "5", 1)
      token!("AA20", corp)
      train = train!(corp, "5")
      route = search(corp, train)[train].find { |r| stop_hexes(r) == %w[AA20 AB27 Z27] }
      detail = detail_of(route)

      expect(detail[:ferries].size).to eq(2) # Valencia-Palma and Palma-Z27
      expect(detail[:ferries].first).to include(ferry: "AA20-AB27", distance: 1)
      counted = detail[:sea].sum { |s| s[:counted] } + detail[:ferries].sum { |f| f[:counted] }
      expect(counted).to be >= game.sea_distance(route) # the detail does not apply the reductions
    end

    it "has no sea stretches for a run over land" do
      lnwr = start_major!(game, "LNWR", game.players[0])
      train = train!(lnwr, "3")
      route = search(lnwr, train)[train].find { |r| !sea?(r) }
      detail = detail_of(route)

      expect(detail).to include(sea: [], ferries: [])
    end
  end

  describe "DSJ Kobenhavn to Malmo (PB 4.5)" do
    before do
      lay_tile!("I52", "57", 0) # Malmo: track to the private port arrow
      token!("I52", dsj)
    end

    it "crosses from Malmo to Kobenhavn and counts the zones as the route does" do
      train = train!(dsj, "3")
      crossing = search(dsj, train)[train].find { |route| stop_hexes(route) == %w[I50 I52] }

      expect(crossing).not_to be_nil
      expect(game.sea_distance(crossing)).to eq(1) # 2 zones, the Malmo token takes one
    end
  end

  describe "Minor J Alger, Valencia and Palma (PB 4.5)" do
    before do
      lay_tile!("AA20", "5", 4) # Valencia: port arrow and ferry end on side 5
      lay_tile!("AB27", "5", 1) # Palma: ferry ends
      token!("AA20", corp)
    end

    it "finds Alger to Valencia over the sea and on to Palma by ferry" do
      train = train!(corp, "5")
      routes = search(corp, train)[train]

      route = routes.find { |r| stop_hexes(r) == %w[AA20 AB27 Z27] }
      expect(route).not_to be_nil
      expect(game.sea_distance(route)).to eq(0) # Chris' reduction pool covers the stretches
      expect(route.revenue).to be_positive
    end
  end

  describe "two crossings without a land hex side between them (§11.3.4)" do
    before do
      lay_tile!("F49", "57", 0) # Goteborg: track to the port arrow
      token!("C48", bjv)
      token!("F49", bjv)
    end

    it "never offers them" do
      train = train!(bjv, "8+8")
      routes = search(bjv, train)[train]

      expect(routes).not_to be_empty
      expect(routes.none? { |route| route.chains.each_cons(2).any? { |a, b| a[:sea] && b[:sea] } }).to be(true)
    end
  end

  describe "a network without a usable port" do
    it "offers no sea crossing" do
      lnwr = start_major!(game, "LNWR", game.players[0]) # London (J27): no port of its own
      train = train!(lnwr, "3")
      routes = search(lnwr, train)[train]

      expect(routes.none? { |route| sea?(route) }).to be(true)
    end
  end
end
