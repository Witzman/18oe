# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE running multiple trains of one RR (§11.3.8)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:corp) { game.corporation_by_id('LNWR') }
  let(:lille) { game.hex_by_id('N31').tile.cities.first }
  let(:london) { game.hex_by_id('M28').tile.cities.first }
  let(:west) { game.hex_by_id('O30').tile.cities.first }
  let(:east) { game.hex_by_id('O32').tile.cities.first }

  def lay_tile!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    game.hex_by_id(hex_id).lay(tile)
  end

  def token!(city, corporation)
    city.place_token(corporation, corporation.next_token, free: true, check_tokenable: false)
  end

  def new_train!
    train = game.trains.find { |t| t.name == '3' && !t.owner.is_a?(Engine::Corporation) }
    game.buy_train(corp, train, :free)
    train
  end

  # Each route is traced on its own, as a player would, and then all are checked together.
  def routes_through(*node_lists)
    routes = node_lists.map do |nodes|
      Engine::Route.new(game, game.phase, new_train!, routes: []).tap do |route|
        route.routes = [route]
        nodes.each { |node| route.touch_node(node) }
      end
    end
    routes.each { |route| route.routes = routes }
  end

  before do
    lay_tile!('N31', 'OE33', 0)
    lay_tile!('O30', '57', 0)
    lay_tile!('O32', '57', 2)
    token!(west, corp)
    token!(lille, corp)
    game.graph.clear
  end

  it 'rejects two trains that use the same track section (§11.3.8)' do
    routes = routes_through([west, lille], [west, lille])

    expect { routes.each(&:revenue) }.to raise_error(Engine::GameError, /Route cannot reuse track/)
  end

  it 'lets two trains count the same city when they enter and leave it by different sections (§11.3.8)' do
    routes = routes_through([west, lille], [lille, east])

    expect(routes.map { |route| route.visited_stops.include?(lille) }).to eq([true, true])
    expect { routes.each(&:revenue) }.not_to raise_error
  end

  it 'pays the shared city to both trains (§11.3.8)' do
    routes = routes_through([west, lille], [lille, east])
    lille_value = lille.route_revenue(game.phase, routes.first.train)

    expect(routes.first.revenue).to be >= lille_value
    expect(routes.last.revenue).to be >= lille_value
  end

  it 'lets two trains of one RR ride the same ferry, Lille to London (§11.3.8 "any number of trains")' do
    pending 'deviation: the ferry track and its city connection count as reusable track, so the second train is refused (workshop #347)'
    routes = routes_through([london, lille, west], [london, lille])

    expect { routes.each(&:revenue) }.not_to raise_error
  end
end
