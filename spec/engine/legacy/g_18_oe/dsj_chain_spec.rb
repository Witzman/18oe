# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #473 (rest of #60), rewritten on Chris' sea API in the triage (#563 Task 8): the long sea crossing example of the
# Playbook, 4.5 (input/18OE_Playbook_v_1.0.txt, lines 804 to 822): the DSJ Major runs a 4 train
# Kobenhavn - Malmo - Karlskrona - (ferry) - Danzig - Konigsberg, and the "alternate route" over Karlskrona's public
# port with a token in Konigsberg.
# Old API -> Chris: sea_units -> sea_distance, route.chains[:sea] -> chain[:crossing], sea_targets/port_token_reducers
# -> sea_legs. Chris' own twin of the numbers is sea_routes_spec 'city limit' (rows 2, 3, 5, 12).
describe 'G18OE the DSJ chain Kobenhavn - Malmo - Karlskrona - Danzig - Konigsberg (PB 4.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:dsj) { game.corporation_by_id('DSJ') }

  def lay_code!(hex_id, code)
    game.hex_by_id(hex_id).lay(Engine::Tile.from_code("X#{hex_id}", :green, code,
                                                      revisitable_nodes: game.class::REVISITABLE_NODES))
    game.graph.clear
  end

  def node(hex_id)
    tile = game.hex_by_id(hex_id).tile
    tile.cities.first || tile.towns.first || tile.offboards.first
  end

  def token!(hex_id)
    dsj.tokens << Engine::Token.new(dsj, price: 0) unless dsj.next_token
    node(hex_id).place_token(dsj, dsj.next_token, free: true, check_tokenable: false)
    game.graph.clear
  end

  def unplace!(hex_id)
    node(hex_id).tokens.compact.each(&:remove!)
    game.graph.clear
  end

  def train(name)
    train = game.trains.find { |t| t.name == name && !t.owner.is_a?(Engine::Corporation) }
    game.buy_train(dsj, train, :free)
    train
  end

  # The stops in order; each pair is joined by the cheapest unused connection (a crossing, land track or the ferry).
  def route_over(name, *hex_ids)
    route = Engine::Route.new(game, game.phase, train(name), routes: [])
    route.routes = [route]
    hex_ids.each_cons(2) do |from, to|
      chain = route.select(node(from), node(to)).first
      raise "no connection #{from} - #{to}" unless chain

      route.connection_data << route.segment(chain, left: node(from))
    end
    route
  end

  def crossing_kinds(route)
    route.chains.map { |chain| chain[:crossing]&.kind }
  end

  # Malmo: private port arrow on side 0 with a token of the RR, track to H53 on side 3. Karlskrona: track to H53
  # (side 1) and to the ferry (side 4, also its public port arrow, §11.3.7). Chris' baltic! of the route helpers.
  def baltic!
    lay_code!('I50', 'city=revenue:30;path=a:1,b:_0;path=a:3,b:_0')
    lay_code!('I52', 'city=revenue:20;path=a:0,b:_0;path=a:3,b:_0')
    lay_code!('H53', 'path=a:0,b:4')
    lay_code!('H55', 'town=revenue:10;path=a:1,b:_0;path=a:4,b:_0')
  end

  describe 'the ferry route' do
    let(:stops) { %w[I50 I52 H55 K60 J63] }

    before do
      baltic!
      lay_code!('K60', 'town=revenue:10;path=a:2,b:_0;path=a:3,b:_0;path=a:4,b:_0')
      lay_code!('K62', 'path=a:1,b:3')
      lay_code!('J63', 'city=revenue:30;path=a:0,b:_0;path=a:1,b:_0')
      token!('I50')
      token!('I52')
    end

    it 'is a sea crossing Kobenhavn - Malmo, then land track, the ferry and land track' do
      route = route_over('4', *stops)
      expect(crossing_kinds(route).compact).to eq(%i[crossing]) # the ferry is a blue-track leg (FerryLeg), not a pathless chain
      expect(game.sea_legs(route).map(&:units)).to eq([2, 1])
      expect(route.chains.first[:crossing].units).to eq(2) # Skagerrak and Baltic Sea
      expect(route.chains.first[:paths]).to be_empty
    end

    it 'counts the two sea zones less the two tokens, plus the ferry distance of one' do
      expect(game.sea_distance(route_over('4', *stops))).to eq(1)
    end

    it 'is a legal 4 train run: three paid cities and the ferry; the towns are passed' do
      route = route_over('4', *stops)
      expect { route.revenue }.not_to raise_error
      expect(route.stops.map { |stop| stop.hex.id }).to contain_exactly('I50', 'I52', 'J63')
      expect(route.distance_str).to eq('3 + 1 sea')
    end

    it 'does not fit a 3 train: three visited cities and the ferry are four places' do
      expect { route_over('3', *stops).revenue }.to raise_error(Engine::RouteTooLong)
    end

    it 'offers no crossing from Kobenhavn into the private Malmo port without the token (§11.3.6)' do
      unplace!('I52')
      expect(game.sea_links(node('I50'), node('I52'), dsj)).to be_empty
    end

    it 'counts one zone more with only the Malmo token (one token is one zone in phase 2 to 6)' do
      unplace!('I50')
      expect(game.sea_distance(route_over('4', *stops))).to eq(2)
    end

    it 'takes both zones with the one Malmo token in phase 7 (two per token)' do
      unplace!('I50')
      at_phase!(game, '7')
      expect(game.sea_distance(route_over('4', *stops))).to eq(1)
    end

    it 'cannot take the ferry distance with a token: no city at either end' do
      route = route_over('4', *stops)
      ferry = game.sea_legs(route).find { |leg| leg.is_a?(Engine::Game::G18OE::FerryLeg) }
      expect(ferry.units).to eq(1)
      expect(ferry.nodes.map { |n| n.hex.id }).to contain_exactly('H55', 'K60')
    end
  end

  describe 'the alternate route over Karlskrona\'s public port with a token in Konigsberg' do
    let(:stops) { %w[I50 I52 H55 J63] }

    before do
      baltic!
      lay_code!('J63', 'city=revenue:30;path=a:0,b:_0;path=a:1,b:_0')
      token!('I50')
      token!('I52')
      token!('J63')
    end

    it 'crosses the Baltic Sea from Karlskrona to Konigsberg as a second sea crossing' do
      route = route_over('3', *stops)
      expect(crossing_kinds(route).compact).to eq(%i[crossing crossing])
      expect(route.chains.filter_map { |chain| chain[:crossing]&.units }).to eq([2, 1])
    end

    it 'counts nothing: the Konigsberg token takes the Baltic Sea zone, the other two tokens the first crossing' do
      expect(game.sea_distance(route_over('3', *stops))).to eq(0)
    end

    it 'is a legal 3 train run: three cities and no ferry distance' do
      route = route_over('3', *stops)
      expect { route.revenue }.not_to raise_error
      expect(route.stops.map { |stop| stop.hex.id }).to contain_exactly('I50', 'I52', 'J63')
    end

    it 'counts the Baltic Sea zone without the Konigsberg token' do
      unplace!('J63')
      expect(game.sea_distance(route_over('3', *stops))).to eq(1)
    end
  end
end
