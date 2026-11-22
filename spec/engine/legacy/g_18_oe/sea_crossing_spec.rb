# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #357 (SC3) and #358 (SC4), rewritten on Chris' sea API in the triage (#563 Task 8): a sea crossing is a route chain
# without track between two port nodes (§11.3.4). The port access is checked, not ridden; every sea zone counts against
# the city limit and takes a place of the row of cities (assumption A1 of #60).
# Old API -> Chris: sea_units -> sea_distance, route.chains[:sea] -> chain[:crossing], port_token_reducers -> the
# token logic inside sea_distance, route.revenue GameError checks -> game.check_other / check_connected, distance_str
# '2+1~' -> '2 + 1 sea'. Chris' own twin is sea_routes_spec (rows 1 to 14).
describe 'G18OE sea crossings (§11.3.4, §11.3.6, §11.3.8)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:dsj) { game.corporation_by_id('DSJ') }
  let(:bjv) { game.corporation_by_id('BJV') }
  let(:corp) { game.corporation_by_id('LNWR') }
  let(:other) { game.corporation_by_id('CHN') } # Barcelona is its home

  def lay_tile!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    game.hex_by_id(hex_id).lay(tile)
    game.graph.clear
  end

  def node(hex_id)
    tile = game.hex_by_id(hex_id).tile
    tile.cities.first || tile.offboards.first
  end

  def token!(hex_id, corporation)
    node(hex_id).place_token(corporation, corporation.next_token, free: true, check_tokenable: false)
    game.graph.clear
  end

  def unplace!(hex_id)
    node(hex_id).tokens.compact.each(&:remove!)
    game.graph.clear
  end

  def train!(corporation, name)
    train = game.trains.find { |t| t.name == name && !t.owner.is_a?(Engine::Corporation) }
    game.buy_train(corporation, train, :free)
    train
  end

  # The stops in order, each pair joined by its cheapest unused connection (a crossing, land track or a ferry).
  def route_over(corporation, name, *hex_ids, routes: [])
    route = Engine::Route.new(game, game.phase, train!(corporation, name), routes: routes)
    routes << route
    hex_ids.each_cons(2) do |from, to|
      chain = route.select(node(from), node(to)).first
      raise "no connection #{from} - #{to}" unless chain

      route.connection_data << route.segment(chain, left: node(from))
    end
    route
  end

  def sea_chain?(chain)
    chain[:paths].empty? && chain[:crossing]&.kind == :crossing
  end

  def links(from, to, corporation)
    game.sea_links(node(from), node(to), corporation)
  end

  describe 'DSJ Kobenhavn to Malmo (PB 4.5)' do
    before do
      lay_tile!('I52', '57', 0) # Malmo: track to the private port arrow (side 0)
      token!('I52', dsj) # the private Malmo port needs it (§11.3.6); it is also a port token (#358)
    end

    it 'crosses from the Kobenhavn offshore port and counts two sea zones' do
      route = route_over(dsj, '4', 'I50', 'I52')

      expect(route.chains.map { |chain| sea_chain?(chain) }).to eq([true])
      expect(route.chains.first[:crossing].units).to eq(2)
      expect(game.sea_distance(route)).to eq(1) # 2 zones, the Malmo token takes one (phase 2)
      expect { route.revenue }.not_to raise_error
      expect(route.stops).to contain_exactly(node('I50'), node('I52'))
      expect(route.distance_str).to eq('2 + 1 sea')
    end

    it 'fits two cities and the one zone the Malmo token leaves on a 3 train (§11.3.3)' do
      route = route_over(dsj, '3', 'I50', 'I52')

      expect { route.revenue }.not_to raise_error
    end

    it 'refuses the same route once the Malmo token is gone (§11.3.6)' do
      unplace!('I52')

      expect(links('I50', 'I52', dsj)).to be_empty # the private Malmo port needs the token (§11.3.6)
    end

    it 'survives a run routes action written out and read back (replay)' do
      route = route_over(dsj, '4', 'I50', 'I52')
      revenue = route.revenue
      action = Engine::Action::RunRoutes.new(dsj, routes: [route])

      back = Engine::Action::Base.action_from_h(action.to_h, game)
      replayed = back.routes.first

      expect(replayed.connection_hexes).to eq(route.connection_hexes)
      expect(replayed.visited_stops).to contain_exactly(node('I50'), node('I52'))
      expect(game.sea_distance(replayed)).to eq(1)
      replayed.clear_cache!(all: false)
      expect(replayed.revenue).to eq(revenue)
    end
  end

  describe 'Alger, Valencia and Palma (PB 4.5, Minor J)' do
    before do
      lay_tile!('AA20', '5', 4) # Valencia: sides 4 and 5 (port arrow and ferry end on side 5)
      lay_tile!('AB27', '5', 1) # Palma: sides 1 and 2 (ferry ends)
      token!('AA20', corp)
    end

    it 'counts one sea zone from Alger to Valencia' do
      route = route_over(corp, '3', 'AF25', 'AA20')

      expect(route.chains.first[:crossing].units).to eq(1)
      expect(game.sea_distance(route)).to eq(0) # one zone, the Valencia token takes it (#358)
      expect { route.revenue }.not_to raise_error
      expect(route.stops).to contain_exactly(node('AF25'), node('AA20'))
    end

    it 'lets the ferry follow the port directly, over the same hex side (§11.3.7)' do
      route = route_over(corp, '5', 'AF25', 'AA20', 'AB27')

      expect(route.chains.map { |chain| sea_chain?(chain) }).to contain_exactly(true, false) # crossing, then the ferry track
      expect(game.sea_distance(route)).to eq(1) # zone 1 + ferry 1, one Valencia token: used once
      expect { route.revenue }.not_to raise_error
    end

    it 'offers no crossing into the private Valencia port without a token (§11.3.6)' do
      unplace!('AA20')
      token!('AB27', corp)

      expect(links('AF25', 'AA20', corp).reject { |chain| chain[:crossing].kind == :ferry }).to be_empty
    end
  end

  describe 'BJV Christiania, Goteborg and Kobenhavn (PB 4.4)' do
    before do
      token!('C48', bjv)
      token!('F49', bjv)
    end

    it 'crosses from the Christiania offshore port without any track (§11.3.6)' do
      route = route_over(bjv, '3', 'C48', 'I50')

      expect(game.sea_distance(route)).to eq(0) # one zone, the Christiania token takes it (#358)
      expect { route.revenue }.not_to raise_error
    end

    it 'offers no crossing from the Goteborg private port without track to its arrow' do
      expect(links('F49', 'I50', bjv)).to be_empty
    end

    it 'refuses two crossings without a land hex side between them (§11.3.4)' do
      lay_tile!('F49', '57', 0) # Goteborg: track to the port arrow
      route = route_over(bjv, '8+8', 'C48', 'I50', 'F49')

      expect(route.chains.count { |chain| sea_chain?(chain) }).to eq(2)
      expect { game.check_other(route) }.to raise_error(Engine::GameError, /land hex side/)
    end

    it 'lets two trains of one RR use the same ports and sea zones (§11.3.8)' do
      routes = []
      route_over(bjv, '3', 'C48', 'I50', routes: routes)
      route_over(bjv, '3', 'C48', 'I50', routes: routes)

      expect(routes.map { |route| route.chains.size }).to eq([1, 1])
      expect { game.check_overlap(routes) }.not_to raise_error
    end
  end

  describe 'a crossing that ends in a city full of foreign tokens (§11.3.6)' do
    before do
      lay_tile!('AB27', '5', 1) # Palma: ferry end on side 2 towards Barcelona
      token!('AB27', corp)
    end

    it 'may run on from Barcelona over the ferry when the city is open' do
      route = route_over(corp, '8+8', 'AF25', 'Z27', 'AB27')

      expect(route.chains.map { |chain| sea_chain?(chain) }).to contain_exactly(true, false) # crossing, then the ferry track
      expect { game.check_connected(route, corp) }.not_to raise_error
    end

    it 'may not pass through Barcelona when another RR fills it' do
      token!('Z27', other)
      route = route_over(corp, '8+8', 'AF25', 'Z27', 'AB27')

      expect(route.chains.map { |chain| sea_chain?(chain) }).to contain_exactly(true, false) # crossing, then the ferry track
      expect { game.check_connected(route, corp) }.to raise_error(Engine::GameError, /not connected/)
    end
  end

  # #358 (SC4): a port token takes sea units off the city limit, per train (§11.3.5, §11.3.7, PB 4.5).
  describe 'port token reduction (§11.3.5, §11.3.7)' do
    def units(corporation, train, *hex_ids)
      game.sea_distance(route_over(corporation, train, *hex_ids))
    end

    describe 'DSJ Kobenhavn and Malmo' do
      before do
        lay_tile!('I52', '57', 0)
        token!('I52', dsj)
      end

      it 'takes one of two zones per token in phase 2 to 6, the Kobenhavn offshore token included' do
        expect(units(dsj, '4', 'I50', 'I52')).to eq(1)
        token!('I50', dsj)

        expect(units(dsj, '4', 'I50', 'I52')).to eq(0)
      end

      it 'takes two zones for one token in phase 7 and 8' do
        at_phase!(game, '7')

        expect(units(dsj, '4', 'I50', 'I52')).to eq(0)
      end

      it 'is spent once per train, not once per RR' do
        routes = []
        first = route_over(dsj, '4', 'I50', 'I52', routes: routes)
        second = route_over(dsj, '4', 'I50', 'I52', routes: routes)

        expect([first, second].map { |route| game.sea_distance(route) }).to eq([1, 1])
      end

      it 'does not take anything for a token of another RR' do
        unplace!('I52')
        token!('I52', bjv) # a private port needs the token of the train's own RR: no crossing at all

        expect(links('I50', 'I52', dsj)).to be_empty
      end
    end

    describe 'BJV Christiania to Kobenhavn' do
      it 'is free with the Christiania token and counts one zone without any token' do
        expect(units(bjv, '3', 'C48', 'I50')).to eq(1)
        token!('C48', bjv)

        expect(units(bjv, '3', 'C48', 'I50')).to eq(0)
      end

      it 'keeps the crossing valid with no zone left to count' do
        token!('C48', bjv)
        route = route_over(bjv, '3', 'C48', 'I50')

        expect(route.chains.map { |chain| sea_chain?(chain) }).to eq([true])
        expect { route.revenue }.not_to raise_error
      end
    end

    describe 'Minor J Alger, Valencia and Palma' do
      before do
        lay_tile!('AA20', '5', 4)
        lay_tile!('AB27', '5', 1)
        token!('AA20', corp)
      end

      it 'uses the Valencia token on the zone or on the ferry, never on both' do
        expect(units(corp, '5', 'AF25', 'AA20', 'AB27')).to eq(1)
      end

      it 'uses both tokens, the Palma token on the ferry beside it, and counts any further zone in full' do
        token!('AB27', corp)

        expect(units(corp, '5', 'AF25', 'AA20', 'AB27')).to eq(0)
      end
    end
  end
end
