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
    train.instance_variable_set(:@requires_token, false)
    train
  end

  def route_over(train, *nodes)
    Engine::Route.new(game, game.phase, train, routes: []).tap do |route|
      route.routes = [route]
      nodes.each_cons(2) do |left, right|
        chain = route.select(left, right).first
        raise "no connection #{left.signature} - #{right.signature}" unless chain

        route.connection_data << route.segment(chain, left: left)
      end
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

      expect(game.sea_distance(route)).to eq(0)
      expect { route.revenue }.not_to raise_error
      expect(route.distance_str).to eq('2')
    end
  end

  describe 'Valencia to Palma, distance 1' do
    before do
      lay_tile!('AB27', '5', 1)
      lay_tile!('AA20', '5', 4)
      # No token at either port: in Chris' model a token in a port city takes the ferry off again (#358, see
      # sea_crossing_spec), so the ferry distance alone is measured with trains that need no token.
      allow(game).to receive(:check_route_token)
      game.graph.clear
    end

    it 'counts the ferry distance' do
      route = route_over(train!('2+2'), city('AA20'), city('AB27'))

      expect(game.sea_distance(route)).to eq(1)
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
      expect(route.distance_str).to eq('2 + 1 sea')
    end

    # The old example drove compute_stops with doubles (4 train: three paid places after the ferry). Chris' twin is
    # sea_routes_spec 'reduces the city row of a 4D train'; here the same on this ferry.
    it 'takes one place of the city row of a 4D train for the ferry' do
      four_d = game.trains.find { |t| t.name == '7+7' }
      four_d.variant = '4D'
      four_d.owner = corp
      route = route_over(four_d, city('AA20'), city('AB27'))
      city_row = ->(rows) { rows.find { |row| row['nodes'].include?('city') } }

      expect(city_row.call(game.route_train_distance(route, four_d))['visit'])
        .to eq(city_row.call(game.train_distance(four_d))['visit'] - game.sea_distance(route))
      expect(game.sea_distance(route)).to eq(1)
    end
  end
end
