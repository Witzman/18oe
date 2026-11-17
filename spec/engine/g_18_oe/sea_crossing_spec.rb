# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #357 (SC3): a sea crossing is a route chain without track between two port nodes (§11.3.4). The port access is
# checked, not ridden; every sea zone counts against the city limit and takes a place of the row of cities
# (assumption A1 of #60).
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

  def route_over(corporation, name, *hex_ids, routes: [])
    Engine::Route.new(game, game.phase, train!(corporation, name), routes: routes).tap do |route|
      routes << route
      hex_ids.each { |hex_id| route.touch_node(node(hex_id)) }
    end
  end

  def sea_chain?(chain)
    chain[:paths].empty? && !chain[:sea].nil?
  end

  describe 'DSJ Kobenhavn to Malmo (PB 4.5)' do
    before do
      lay_tile!('I52', '57', 0) # Malmo: track to the private port arrow (side 0)
      token!('I50', dsj)
      token!('I52', dsj)
      game.graph.clear
    end

    it 'crosses from the Kobenhavn offshore port and counts two sea zones' do
      route = route_over(dsj, '4', 'I50', 'I52')

      expect(route.chains.map { |chain| sea_chain?(chain) }).to eq([true])
      expect(game.sea_units(route)).to eq(2)
      expect { route.revenue }.not_to raise_error
      expect(route.stops).to contain_exactly(node('I50'), node('I52'))
      expect(route.distance_str).to eq('2+2~')
    end

    it 'refuses two cities and two sea zones on a 3 train (§11.3.3)' do
      route = route_over(dsj, '3', 'I50', 'I52')

      expect { route.revenue }.to raise_error(Engine::RouteTooLong)
    end

    it 'survives a run routes action written out and read back (replay)' do
      route = route_over(dsj, '4', 'I50', 'I52')
      revenue = route.revenue
      action = Engine::Action::RunRoutes.new(dsj, routes: [route])

      back = Engine::Action::Base.action_from_h(action.to_h, game)
      replayed = back.routes.first

      expect(replayed.connection_hexes).to eq(route.connection_hexes)
      expect(replayed.visited_stops).to contain_exactly(node('I50'), node('I52'))
      expect(game.sea_units(replayed)).to eq(2)
      replayed.clear_cache!(all: false)
      expect(replayed.revenue).to eq(revenue)
    end
  end

  describe 'Alger, Valencia and Palma (PB 4.5, Minor J)' do
    before do
      lay_tile!('AA20', '5', 4) # Valencia: sides 4 and 5 (port arrow and ferry end on side 5)
      lay_tile!('AB27', '5', 1) # Palma: sides 1 and 2 (ferry ends)
      token!('AA20', corp)
      game.graph.clear
    end

    it 'counts one sea zone from Alger to Valencia' do
      route = route_over(corp, '3', 'AF25', 'AA20')

      expect(game.sea_units(route)).to eq(1)
      expect { route.revenue }.not_to raise_error
      expect(route.stops).to contain_exactly(node('AF25'), node('AA20'))
    end

    it 'lets the ferry follow the port directly, over the same hex side (§11.3.7)' do
      route = route_over(corp, '5', 'AF25', 'AA20', 'AB27')

      expect(route.chains.map { |chain| sea_chain?(chain) }).to contain_exactly(true, false)
      expect(game.sea_units(route)).to eq(2)
      expect { route.revenue }.not_to raise_error
    end

    it 'offers no crossing into the private Valencia port without a token (§11.3.6)' do
      node('AA20').tokens.each(&:remove!)
      token!('AB27', corp)
      route = route_over(corp, '5', 'AF25', 'AA20')

      expect(route.chains).to be_empty
    end
  end

  describe 'BJV Christiania, Goteborg and Kobenhavn (PB 4.4)' do
    before do
      token!('C48', bjv)
      token!('F49', bjv)
      game.graph.clear
    end

    it 'crosses from the Christiania offshore port without any track (§11.3.6)' do
      route = route_over(bjv, '3', 'C48', 'I50')

      expect(game.sea_units(route)).to eq(1)
      expect { route.revenue }.not_to raise_error
    end

    it 'offers no crossing from the Goteborg private port without track to its arrow' do
      route = route_over(bjv, '8+8', 'F49', 'I50')

      expect(route.chains).to be_empty
    end

    it 'refuses two crossings without a land hex side between them (§11.3.4)' do
      lay_tile!('F49', '57', 0) # Goteborg: track to the port arrow
      game.graph.clear
      route = route_over(bjv, '8+8', 'C48', 'I50', 'F49')

      expect(route.chains.count { |chain| sea_chain?(chain) }).to eq(2)
      expect { route.revenue }.to raise_error(Engine::GameError, /land hex side/)
    end

    it 'lets two trains of one RR use the same ports and sea zones (§11.3.8)' do
      routes = []
      route_over(bjv, '3', 'C48', 'I50', routes: routes)
      route_over(bjv, '3', 'C48', 'I50', routes: routes)

      expect(routes.map { |route| route.chains.size }).to eq([1, 1])
      expect { routes.each(&:revenue) }.not_to raise_error
    end
  end

  describe 'a crossing that ends in a city full of foreign tokens (§11.3.6)' do
    before do
      lay_tile!('AB27', '5', 1) # Palma: ferry end on side 2 towards Barcelona
      token!('AB27', corp)
      game.graph.clear
    end

    it 'may run on from Barcelona over the ferry when the city is open' do
      route = route_over(corp, '8+8', 'AF25', 'Z27', 'AB27')

      expect(route.chains.map { |chain| sea_chain?(chain) }).to contain_exactly(true, false)
      expect { route.revenue }.not_to raise_error
    end

    it 'may not pass through Barcelona when another RR fills it' do
      token!('Z27', other)
      route = route_over(corp, '8+8', 'AF25', 'Z27', 'AB27')

      expect(route.chains.map { |chain| sea_chain?(chain) }).to contain_exactly(true, false)
      expect { route.revenue }.to raise_error(Engine::GameError, /not connected/)
    end
  end
end
