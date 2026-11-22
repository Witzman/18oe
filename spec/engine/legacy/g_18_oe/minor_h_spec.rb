# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #73: Minor H (Great Western Steamship Company, §15.8, §11.3.5) reduces the sea zones and ferry distance that count
# against its RR's trains' city limits: by 1 in Train Phases 2 to 6, by 2 in Phases 7 and 8. The reduction applies to
# the RR, not to each train, so the trains of one RR share it. It does not change what crossing water costs to lay
# track or tokens (§11.3.5, §11.1.6, §11.2.1).
describe 'G18OE minor H, Great Western Steamship (§15.8, §11.3.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:dsj) { game.corporation_by_id('DSJ') }
  let(:steamship) { game.corporation_by_id('H').abilities.first }

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

  describe 'the allowance of a RR' do
    it 'is 1 in Train Phases 2 to 6 and 2 in Phases 7 and 8 for the holder of the ability' do
      dsj.add_ability(steamship)

      amounts = %w[2 3 4 5 6 7 8].to_h do |phase|
        at_phase!(game, phase)
        [phase, game.steamship_allowance(dsj, game.phase)]
      end

      expect(amounts).to eq('2' => 1, '3' => 1, '4' => 1, '5' => 1, '6' => 1, '7' => 2, '8' => 2)
    end

    it 'is 0 for a RR without the ability' do
      expect(game.steamship_allowance(dsj, game.phase)).to eq(0)
    end
  end

  # DSJ from Kobenhavn to Malmo (PB 4.5): two sea zones, the Malmo token takes one (phase 2), so one unit remains.
  describe 'a sea crossing, Kobenhavn to Malmo' do
    before do
      lay_tile!('I52', '57', 0)
      token!('I52', dsj)
      game.graph.clear
    end

    it 'refuses two cities and the remaining unit on a 2 train without the minor' do
      route = route_over(dsj, '2+2', 'I50', 'I52')

      expect(game.sea_units(route)).to eq(1)
      expect { route.revenue }.to raise_error(Engine::RouteTooLong)
    end

    it 'takes that unit off for the holder, so a 2 train runs both cities' do
      dsj.add_ability(steamship)
      route = route_over(dsj, '2+2', 'I50', 'I52')

      expect { route.revenue }.not_to raise_error
      expect(route.stops).to contain_exactly(node('I50'), node('I52'))
      expect(route.distance_str).to eq('2')
    end

    it 'uses the reduction only as far as a route needs it' do
      dsj.add_ability(steamship)
      route = route_over(dsj, '3', 'I50', 'I52')
      route.revenue

      expect(route.distance_str).to eq('2+1~')
    end

    it 'is shared by the trains of the RR: a second train that needs it too is refused (§11.3.5)' do
      dsj.add_ability(steamship)
      routes = []
      first = route_over(dsj, '2+2', 'I50', 'I52', routes: routes)
      second = route_over(dsj, '2+2', 'I50', 'I52', routes: routes)

      expect { first.revenue }.not_to raise_error
      expect { second.revenue }.to raise_error(Engine::RouteTooLong)
    end

    it 'lets a second train run when it needs none of it' do
      dsj.add_ability(steamship)
      routes = []
      first = route_over(dsj, '2+2', 'I50', 'I52', routes: routes)
      second = route_over(dsj, '3', 'I50', 'I52', routes: routes)

      expect { first.revenue }.not_to raise_error
      expect { second.revenue }.not_to raise_error
    end
  end

  # Valencia to Palma, ferry of distance 1 (§11.3.7): the minor reduces ferry distance as well.
  describe 'a ferry, Valencia to Palma' do
    before do
      lay_tile!('AB27', '5', 1)
      lay_tile!('AA20', '5', 4)
      token!('AA20', dsj)
      allow(game).to receive(:port_token_reducers).and_return([]) # the token would take the ferry off again (#358)
      game.graph.clear
    end

    it 'refuses two cities and the ferry on a 2 train without the minor' do
      route = route_over(dsj, '2+2', 'AA20', 'AB27')

      expect { route.revenue }.to raise_error(Engine::RouteTooLong)
    end

    it 'takes the ferry distance off for the holder' do
      dsj.add_ability(steamship)
      route = route_over(dsj, '2+2', 'AA20', 'AB27')

      expect { route.revenue }.not_to raise_error
      expect(route.distance_str).to eq('2')
    end
  end

  # Danzig (K60) and Karlskrona (H55): the ferry of distance 1 costs £5 for a tile and £20 for a token (#61).
  describe 'the cost of crossing water' do
    let(:lnwr) { start_major!(game, 'LNWR', game.players.first) }

    def rotated(name, exit)
      tile = game.tiles.find { |t| t.name == name && !t.hex && t.exits.size == 2 }
      tile.rotate!((0..5).find { |r| tile.rotate!(r) && tile.exits.include?(exit) })
      tile
    end

    def fees
      [game.cross_water_track_fee(lnwr, game.hex_by_id('H55'), rotated('57', 4)),
       game.cross_water_token_fee(lnwr, game.hex_by_id('K60').tile.cities.first)]
    end

    it 'does not change for the holder of the ability (§11.3.5)' do
      lnwr
      game.hex_by_id('K60').lay(rotated('57', 2))
      token!('K60', lnwr)
      game.graph.clear
      before = fees

      lnwr.add_ability(steamship)
      game.graph.clear

      expect(before.first).to eq(5)
      expect(fees).to eq(before)
    end
  end
end
