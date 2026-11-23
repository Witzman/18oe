# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

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
    routes = routes_through([london, lille, west], [london, lille])

    expect { routes.each(&:revenue) }.not_to raise_error
  end

  it 'still rejects two trains that share the land section behind the ferry (§11.3.8, London must be left differently)' do
    routes = routes_through([london, lille, west], [london, lille, west])

    expect { routes.each(&:revenue) }.to raise_error(Engine::GameError, /Route cannot reuse track/)
  end

  it 'treats the ferry line and both city sections of it as shared sea traffic, and no land track' do
    ferry = game.hex_by_id('N29').tile.paths.first
    london_section = london.paths.find { |path| path.exits.include?(5) }
    lille_ferry = lille.paths.find { |path| path.exits.include?(1) }
    land = lille.paths.find { |path| path.exits.include?(4) }

    expect([ferry, london_section, lille_ferry].map { |path| game.shared_track?(path) }).to eq([true, true, true])
    expect(game.shared_track?(land)).to be(false)
  end

  it 'leaves the ferry free for a second train while drawing its route' do
    routes = routes_through([london, lille])
    held = routes.first.paths

    expect(game.compute_other_paths(routes + [routes.first.dup], routes.first)).not_to include(*held.select { |path| game.shared_track?(path) })
    expect(held.count { |path| game.shared_track?(path) }).to eq(3)
  end

  it 'lets the second route be drawn over the ferry the first one already rides (touch_node)' do
    first = routes_through([london, lille]).first
    second = Engine::Route.new(game, game.phase, new_train!, routes: [first])
    second.routes = [first, second]
    [london, lille].each { |node| second.touch_node(node) }

    expect(second.visited_stops).to contain_exactly(london, lille)
    expect { [first, second].each(&:revenue) }.not_to raise_error
  end
end

describe 'G18OE route picker with two trains on one ferry (§11.3.8)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:corp) { game.corporation_by_id('LNWR') }

  def lay_tile!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    game.hex_by_id(hex_id).lay(tile)
  end

  it 'sends both trains over the Lille ferry to London, one from each side' do
    lay_tile!('N31', 'OE33', 0)
    lay_tile!('O30', '57', 0)
    lay_tile!('O32', '57', 2)
    %w[O30 O32].each do |hex_id|
      game.hex_by_id(hex_id).tile.cities.first.place_token(corp, corp.next_token, free: true, check_tokenable: false)
    end
    2.times { game.buy_train(corp, game.trains.find { |t| t.name == '3' && !t.owner.is_a?(Engine::Corporation) }, :free) }
    game.graph.clear

    routes = Oe::LegalActions::RoutePicker.new(game, corp).call

    expect(routes.map { |route| route.visited_stops.map { |stop| stop.hex.id }.sort })
      .to contain_exactly(%w[M28 N31 O30], %w[M28 N31 O32])
    expect(routes.map(&:revenue)).to all(be >= 110)
  end
end
