# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #356 (SC2): the ferry distance (0 or 1, §11.3.7) counts against the city limit (§11.3.3), and takes a place of
# the row of cities (assumption A1 of #60): fewer stops to visit and to pay.
describe 'G18OE ferry distance on the city limit (§11.3.3, §11.3.7)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:corp) { game.corporation_by_id('LNWR') }

  def lay_tile!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    game.hex_by_id(hex_id).lay(tile)
  end

  def city(hex_id)
    game.hex_by_id(hex_id).tile.cities.first
  end

  def token!(hex_id, corporation = corp)
    city(hex_id).place_token(corporation, corporation.next_token, free: true, check_tokenable: false)
  end

  def train!(name)
    train = game.trains.find { |t| t.name == name && !t.owner.is_a?(Engine::Corporation) }
    game.buy_train(corp, train, :free)
    train
  end

  def route_over(train, *nodes)
    Engine::Route.new(game, game.phase, train, routes: []).tap do |route|
      route.routes = [route]
      nodes.each { |node| route.touch_node(node) }
    end
  end

  describe 'Lille to London, distance 0' do
    before do
      lay_tile!('N31', 'OE33', 0)
      token!('N31')
      game.graph.clear
    end

    it 'costs nothing on a 2 train (two cities)' do
      route = route_over(train!('2+2'), city('M28'), city('N31'))

      expect(game.sea_units(route)).to eq(0)
      expect { route.revenue }.not_to raise_error
      expect(route.distance_str).to eq('2')
    end
  end

  describe 'Valencia to Palma, distance 1' do
    before do
      lay_tile!('AB27', '5', 1)
      lay_tile!('AA20', '5', 4)
      token!('AA20')
      # The token that connects the route would take the ferry off again (#358, sea_crossing_spec): this spec
      # measures the ferry distance alone.
      allow(game).to receive(:port_token_reducers).and_return([])
      game.graph.clear
    end

    it 'counts the ferry distance' do
      route = route_over(train!('2+2'), city('AA20'), city('AB27'))

      expect(game.sea_units(route)).to eq(1)
    end

    it 'refuses two cities and the ferry on a 2 train' do
      route = route_over(train!('2+2'), city('AA20'), city('AB27'))

      expect { route.revenue }.to raise_error(Engine::RouteTooLong)
    end

    it 'lets a 3 train run two cities and the ferry and pays both cities' do
      train = train!('3')
      route = route_over(train, city('AA20'), city('AB27'))

      expect { route.revenue }.not_to raise_error
      expect(route.stops).to contain_exactly(city('AA20'), city('AB27'))
      expect(route.distance_str).to eq('2+1~')
    end

    it 'pays only three places on a 4 train with three cities and the ferry' do
      stops = Array.new(4) { |i| double("city #{i}", type: 'city', tokened_by?: i.zero?, route_revenue: 10 * (i + 1)) }
      route = double('route', train: train!('4'), phase: game.phase, corporation: corp)
      allow(game).to receive(:revenue_stops).with(route).and_return(stops)
      allow(game).to receive(:orient_express_bonus_route?).and_return(false)
      allow(game).to receive(:sea_units).with(route).and_return(1)

      expect(game.compute_stops(route).size).to eq(3)
    end
  end
end
