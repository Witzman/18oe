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
    routes, = described_class.new(game).path(trains, corporation, walk_limit: Oe::LegalActions::RoutePicker::WALK_LIMIT)
    routes
  end

  def stop_hexes(route)
    route.visited_stops.map { |stop| stop.hex.id }.sort
  end

  def sea?(route)
    route.chains.any? { |chain| chain[:sea] }
  end

  describe "BJV Christiania to Kobenhavn (PB 4.4)" do
    before { token!("C48", bjv) }

    it "finds the crossing from the Christiania offshore port, with no track at all" do
      train = train!(bjv, "3")
      routes = search(bjv, train)[train]

      crossing = routes.find { |route| stop_hexes(route) == %w[C48 I50] }
      expect(crossing).not_to be_nil
      expect(sea?(crossing)).to be(true)
      expect(game.sea_units(crossing)).to eq(0) # one zone, the Christiania token takes it
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
      info = Struct.new(:routes, :revenues, :segments, :stops)
        .new({ train => route.connection_hexes }, { train => 0 }, { train => [] }, { train => [] })

      expect(route.connection_hexes.flatten).to include(a_string_starting_with("sea "))
      expect(Oe::View.run_detail(info, train)[:hexes]).to eq(%w[C48 I50])
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
        info = Engine::OperatingInfo.new([route], nil, route.revenue, [])
        detail = Oe::View.run_detail(info, route.train)

        expect(detail[:segments]).not_to be_empty
        expect(detail[:segments].map { |s| s[:hex] }.chunk(&:itself).map(&:first)).to eq(detail[:hexes].uniq)
      end
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
      expect(game.sea_units(crossing)).to eq(1) # 2 zones, the Malmo token takes one
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

      route = routes.find { |r| stop_hexes(r) == %w[AA20 AB27 AF25] }
      expect(route).not_to be_nil
      expect(game.sea_units(route)).to eq(1) # zone 1 + ferry 1, the Valencia token used once
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
    it "walks only the land pass, as before" do
      lnwr = start_major!(game, "LNWR", game.players[0]) # London (J27): no port of its own
      train = train!(lnwr, "3")
      game.graph.clear
      router = described_class.new(game)
      routes, = router.path([train], lnwr, walk_limit: 10_000, sea_walk_limit: 10_000)
      walks = router.walks

      allow_any_instance_of(described_class).to receive(:sea_pass?).and_return(false)
      land = described_class.new(game)
      land.path([train], lnwr, walk_limit: 10_000)

      expect(walks).to eq(land.walks)
      expect(routes[train].none? { |route| sea?(route) }).to be(true)
    end
  end
end
