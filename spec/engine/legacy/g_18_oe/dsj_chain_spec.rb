# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #473 (rest of #60): the long sea crossing example of the Playbook, 4.5 (page 10): the DSJ Major runs a 4 train
# Kobenhavn - Malmo - Karlskrona - (ferry) - Danzig - Konigsberg.
#
# What the Playbook says (input/18OE_Playbook_v_1.0.txt, lines 804 to 822, "4.5 Sea Crossings"):
#  - route begins in Kobenhavn, leaves by the offshore public port into Skagerrak and passes two sea zones
#    (Skagerrak, Baltic Sea) to Malmo;
#  - the tokens in Kobenhavn and Malmo reduce the sea zones that count against the city limit by two: "the two seas
#    crossed don't count" (phase 2 to 6: one per token);
#  - then on to the town Karlskrona, over the ferry to the town Danzig, finishing in the city Konigsberg;
#  - the ferry's distance is one and no DSJ token is beside it (no city at either end): it counts against the limit;
#  - a DSJ token in Konigsberg would remove the sea distance Karlskrona - Konigsberg over the Baltic Sea (Karlskrona's
#    public port instead of the ferry): the "alternate route".
# The Playbook gives no revenue for it. The land track between the stops (Malmo - Karlskrona over H53, Danzig -
# Konigsberg over Elbing K62) is not drawn in the text; the spec lays the shortest track (assumption).
describe 'G18OE the DSJ chain Kobenhavn - Malmo - Karlskrona - Danzig - Konigsberg (PB 4.5)' do
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
    tile.cities.first || tile.towns.first || tile.offboards.first
  end

  # DSJ has two tokens before it has started; the alternate route needs a third (Kobenhavn, Malmo, Konigsberg).
  def token!(hex_id)
    dsj.tokens << Engine::Token.new(dsj, price: 0) unless dsj.next_token
    node(hex_id).place_token(dsj, dsj.next_token, free: true, check_tokenable: false)
  end

  def route_over(name, *hex_ids)
    train = game.trains.find { |t| t.name == name && !t.owner.is_a?(Engine::Corporation) }
    game.buy_train(dsj, train, :free)
    Engine::Route.new(game, game.phase, train, routes: []).tap do |route|
      route.routes = [route]
      hex_ids.each { |hex_id| route.touch_node(node(hex_id)) }
    end
  end

  def sea?(chain)
    chain[:paths].empty? && !chain[:sea].nil?
  end

  # Malmo: private port arrow on side 0 with a token of the RR, track to H53 on side 3. Karlskrona: track to H53
  # (side 1) and to the ferry (side 4, which is also its public port arrow, §11.3.7).
  def lay_malmo_to_karlskrona!
    lay_tile!('I52', '57', 0)
    lay_tile!('H53', '8', 4)
    lay_tile!('H55', '4', 1)
    token!('I50')
    token!('I52')
  end

  describe 'the ferry route' do
    before do
      lay_malmo_to_karlskrona!
      lay_tile!('K60', '58', 2) # Danzig: the ferry end on side 2, track to Elbing on side 4
      lay_tile!('K62', '58', 1) # Elbing: sides 1 and 3
      lay_tile!('J63', '57', 0) # Konigsberg: track to Elbing on side 0
      game.graph.clear
    end

    # Elbing (K62) lies between Danzig and Konigsberg: a town on the track, visited like Karlskrona and Danzig
    let(:stops) { %w[I50 I52 H55 K60 K62 J63] }

    it 'is a sea crossing Kobenhavn - Malmo, then land track, the ferry and land track' do
      route = route_over('4', *stops)

      expect(route.chains.count { |chain| sea?(chain) }).to eq(1)
      expect(route.chains.size).to eq(5) # sea, Malmo - Karlskrona, ferry, Danzig - Elbing, Elbing - Konigsberg
      expect(route.chains.find { |chain| sea?(chain) }[:sea][:zones]).to eq(2) # Skagerrak and Baltic Sea
      expect(route.paths.count { |path| game.ferry_path?(path) }).to be_positive
    end

    it 'counts the two sea zones less the two tokens, plus the ferry distance of one' do
      expect(game.sea_units(route_over('4', *stops))).to eq(1)
    end

    # A 4 train visits towns for free (pay 0) and pays four places of city, offboard or town: the ferry takes one,
    # so the three cities are paid and Karlskrona, Danzig and Elbing are passed.
    it 'is a legal 4 train run: three paid cities and the ferry; the towns are passed' do
      route = route_over('4', *stops)

      expect { route.revenue }.not_to raise_error
      expect(route.stops.map { |stop| stop.hex.id }).to contain_exactly('I50', 'I52', 'J63')
      expect(route.visited_stops.size).to eq(6)
      expect(route.distance_str).to eq('6+1~')
    end

    it 'does not fit a 3 train: three visited cities and the ferry are four places' do
      route = route_over('3', *stops)

      expect { route.revenue }.to raise_error(Engine::RouteTooLong)
    end

    it 'offers no crossing from Kobenhavn into the private Malmo port without the token (§11.3.6)' do
      node('I52').tokens.compact.each(&:remove!)
      game.graph.clear

      sea_nodes = route_over('4', *stops).chains.select { |chain| sea?(chain) }.map { |chain| chain[:nodes].map { |n| n.hex.id } }

      expect(sea_nodes).not_to include(%w[I50 I52]) # Kobenhavn may still cross to Karlskrona's public port
    end

    it 'counts one zone more with only the Malmo token (one token is one zone in phase 2 to 6)' do
      node('I50').tokens.compact.each(&:remove!)
      game.graph.clear

      expect(game.sea_units(route_over('4', *stops))).to eq(2) # 2 zones - 1 + ferry 1
    end

    it 'takes both zones with the one Malmo token in phase 7 (two per token)' do
      node('I50').tokens.compact.each(&:remove!)
      at_phase!(game, '7')
      game.graph.clear

      expect(game.sea_units(route_over('4', *stops))).to eq(1) # 2 zones - 2 + ferry 1
    end

    it 'cannot take the ferry distance with a token: no city at either end' do
      route = route_over('4', *stops)
      ferry = game.sea_targets(route).find { |target| target.ref.is_a?(Engine::Game::G18OE::Sea::FerryComponent) }

      expect(ferry.units).to eq(1)
      expect(ferry.hex_ids).to contain_exactly('H55', 'K60')
      expect(game.port_token_reducers(route).flat_map(&:hex_ids)).to contain_exactly('I50', 'I52')
    end
  end

  describe 'the alternate route over Karlskrona\'s public port with a token in Konigsberg' do
    before do
      lay_malmo_to_karlskrona!
      lay_tile!('J63', '57', 1) # Konigsberg: track to the public port arrow on side 1
      token!('J63')
      game.graph.clear
    end

    let(:stops) { %w[I50 I52 H55 J63] }

    it 'crosses the Baltic Sea from Karlskrona to Konigsberg as a second sea crossing' do
      route = route_over('3', *stops)

      expect(route.chains.map { |chain| sea?(chain) }).to contain_exactly(true, false, true)
      expect(route.chains.select { |chain| sea?(chain) }.map { |chain| chain[:sea][:zones] }).to contain_exactly(2, 1)
    end

    it 'counts nothing: the Konigsberg token takes the Baltic Sea zone, the other two tokens the first crossing' do
      expect(game.sea_units(route_over('3', *stops))).to eq(0)
    end

    it 'is a legal 3 train run: three cities and no ferry distance' do
      route = route_over('3', *stops)

      expect { route.revenue }.not_to raise_error
      expect(route.stops.map { |stop| stop.hex.id }).to contain_exactly('I50', 'I52', 'J63')
      expect(route.distance_str).to eq('4')
    end

    it 'counts the Baltic Sea zone without the Konigsberg token' do
      node('J63').tokens.compact.each(&:remove!)
      game.graph.clear

      expect(game.sea_units(route_over('3', *stops))).to eq(1)
    end
  end
end
