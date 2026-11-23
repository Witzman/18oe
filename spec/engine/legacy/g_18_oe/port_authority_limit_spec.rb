# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #56 part 3, rewritten on Chris' port authority model in the triage (#563 Task 8): a port authority marker takes two
# sea zones in its water area off the city limits of its RR's trains (§11.3.5, §11.3.4). The reduction belongs to the
# RR (the trains share it, a split between two trains is allowed); it applies to sea zones of its area only, not to
# ferries and not to the other water area.
# Old API -> Chris: @port_authority_owners[corp] = area -> @port_authorities[corp] = [sea] (a list, limit 1 per major in
# PORT_AUTHORITY_LIMIT), port_authority_allowance -> sea_pool, route.revenue RouteTooLong / sea_pool_allocation.
# Chris' own twins: sea_routes_spec 'port authorities and Minor H' and 'sharing the pool across the railroad's trains'.
describe 'G18OE port authority and the city limit (§11.3.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:dsj) { game.corporation_by_id('DSJ') }

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
    route = Engine::Route.new(game, game.phase, train!(corporation, name), routes: routes)
    routes << route
    hex_ids.each_cons(2) do |from, to|
      chain = route.select(node(from), node(to)).first
      route.connection_data << route.segment(chain, left: node(from))
    end
    route
  end

  def own!(sea)
    game.instance_variable_get(:@port_authorities)[dsj] = [sea]
    game.graph.clear
  end

  # Kobenhavn to Malmo (PB 4.5): two sea zones (Baltic), the Malmo token takes one in phase 2: one unit remains.
  before do
    lay_tile!('I52', '57', 0)
    token!('I52', dsj)
    game.graph.clear
  end

  it 'has a pool of two for the owner of a marker and none otherwise' do
    expect(game.sea_pool_total(dsj, game.phase)).to eq(0)
    own!(:north_sea)

    expect(game.sea_pool_total(dsj, game.phase)).to eq(2)
  end

  it 'refuses two cities on a 2 train without the marker' do
    route = route_over(dsj, '2+2', 'I50', 'I52')

    expect { route.revenue }.to raise_error(Engine::RouteTooLong)
  end

  it 'takes the remaining sea zone off for the marker of the crossing\'s area' do
    own!(:north_sea)
    route = route_over(dsj, '2+2', 'I50', 'I52')

    expect { route.revenue }.not_to raise_error
    expect(route.distance_str).to eq('2')
  end

  it 'takes nothing off for the marker of the other area' do
    own!(:mediterranean)
    route = route_over(dsj, '2+2', 'I50', 'I52')

    expect { route.revenue }.to raise_error(Engine::RouteTooLong)
  end

  it 'is shared by the trains of the RR: two trains that need one unit each use up the two units' do
    own!(:north_sea)
    routes = []
    first = route_over(dsj, '2+2', 'I50', 'I52', routes: routes)
    second = route_over(dsj, '2+2', 'I50', 'I52', routes: routes)
    third = route_over(dsj, '2+2', 'I50', 'I52', routes: routes)

    expect { first.revenue }.not_to raise_error
    expect { second.revenue }.not_to raise_error
    expect { third.revenue }.to raise_error(Engine::RouteTooLong)
  end

  # #472: Minor H and the marker are both the RR's; the split of their units over the trains must not be decided
  # train by train (Minor H first for each), or the third train is refused though 1 + 2 units cover three trains.
  it 'with Minor H too: three trains that need one unit each pass with Minor H (1) and the marker (2) (#472)' do
    dsj.add_ability(game.corporation_by_id('H').abilities.first)
    own!(:north_sea)
    routes = []
    3.times { route_over(dsj, '2+2', 'I50', 'I52', routes: routes) }

    routes.each { |route| expect { route.revenue(suppress_check_route_combination: true) }.not_to raise_error }
    expect { game.check_overlap(routes) }.not_to raise_error
    expect(game.sea_pool_total(dsj, game.phase)).to eq(3)
  end
end
