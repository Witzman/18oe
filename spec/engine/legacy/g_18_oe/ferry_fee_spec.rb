# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #61: the ferry part of the cross-water fees. A tile (§11.1.6) or a token (§11.2.1) the hypothetical train reaches
# over a ferry costs £5 (tile) or £20 (token) times the ferry's distance; the sea zone part is in cross_water_spec.
# Port categories do not change the fee. A ferry of distance 0 costs nothing.
describe 'G18OE ferry fees for track and tokens (§11.1.6, §11.2.1)' do
  include G18OESpecHelpers

  # majors build outside their track-rights zone only after the first merger (upstream 46330521f, #600)
  let(:game) { new_game.tap(&:minor_merged) }
  let(:player) { game.players.first }
  let(:lnwr) { start_major!(game, 'LNWR', player) }

  def hex(hex_id)
    game.hex_by_id(hex_id)
  end

  def rotated(name, exit)
    tile = game.tiles.find { |t| t.name == name && !t.hex && t.exits.size == 2 }
    tile.rotate!((0..5).find { |r| tile.rotate!(r) && tile.exits.include?(exit) })
    tile
  end

  def lay!(hex_id, name, exit)
    tile = rotated(name, exit)
    hex(hex_id).lay(tile)
    game.graph.clear
    tile
  end

  def token!(hex_id, corporation)
    city = hex(hex_id).tile.cities.first
    city.place_token(corporation, corporation.next_token, free: true, check_tokenable: false)
    game.graph.clear
  end

  def cash!(corporation, amount)
    diff = amount - corporation.cash
    diff.positive? ? game.bank.spend(diff, corporation) : corporation.spend(-diff, game.bank)
  end

  def track_step
    enter_round!(game, game.operating_round(1)).steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::Track) }
  end

  def token_step
    enter_round!(game, game.operating_round(1)).steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::Token) }
  end

  # Danzig (K60, exit 2) and Karlskrona (H55, exit 4) lie at the two ends of one ferry of distance 1.
  describe 'the ferry Danzig - Karlskrona (distance 1)' do
    before do
      lnwr
      lay!('K60', '57', 2)
      token!('K60', lnwr)
    end

    it 'charges £5 for a tile on the far shore (§11.1.6)' do
      expect(game.cross_water_tile_fee(lnwr, hex('H55'), rotated('57', 4))).to eq(5)
    end

    it 'charges £20 for a token on the far shore (§11.2.1)' do
      lay!('H55', '57', 4)

      expect(game.cross_water_token_fee(lnwr, hex('H55').tile.cities.first)).to eq(20)
    end

    it 'charges nothing for a tile on the near shore' do
      expect(game.cross_water_tile_fee(lnwr, hex('K60'), rotated('57', 2))).to eq(0)
    end

    it 'charges nothing to a national (§11.1.5)' do
      lnwr.type = :national

      expect(game.cross_water_tile_fee(lnwr, hex('H55'), rotated('57', 4))).to eq(0)
    end

    it 'pays the ferry with the tile and records the fee on the action (§11.1.6)' do
      cash!(lnwr, 500)
      step = track_step
      game.round.instance_variable_set(:@entities, [lnwr])
      tile = rotated('3', 4)
      rotation = step.legal_tile_rotations(lnwr, hex('H55'), tile).find do |r|
        tile.rotate!(r)
        tile.exits.include?(4)
      end
      expect(rotation).not_to be_nil
      before = lnwr.cash

      action = Engine::Action::LayTile.new(lnwr, tile: tile, hex: hex('H55'), rotation: rotation)
      step.process_lay_tile(action)

      # Chris: the fee travels on the action (extra_cost, checked on replay); the log line is the core's
      # "spends £X and lays tile" line, the old fee sentence is player text of the wrapper (text.ts).
      expect(action.extra_cost).to eq(5)
      expect(before - lnwr.cash).to be >= 5
    end

    it 'pays the ferry with the token and records the cost on the action (§11.2.1)' do
      lay!('H55', '57', 4)
      cash!(lnwr, 1000)
      token = lnwr.next_token
      price = token.price

      action = Engine::Action::PlaceToken.new(lnwr, city: hex('H55').tile.cities.first, slot: 0)
      token_step.process_place_token(action)

      expect(action.cost).to eq(price + 20)
      expect(lnwr.cash).to eq(1000 - price - 20)
    end
  end

  # Nice (X37, exit 5) and Ajaccio (Z41, exit 2) lie at the two ends of a ferry of distance 0: it is free.
  describe 'the ferry Nice - Ajaccio (distance 0)' do
    before do
      lnwr
      lay!('X37', '57', 5)
      token!('X37', lnwr)
    end

    it 'charges nothing for a tile or a token on the far shore' do
      expect(game.cross_water_tile_fee(lnwr, hex('Z41'), rotated('57', 2))).to eq(0)
      lay!('Z41', '57', 2)

      expect(game.cross_water_token_fee(lnwr, hex('Z41').tile.cities.first)).to eq(0)
    end
  end

  # #445: a ferry behind a sea landing. From Antwerp's port (X33) the train crosses 3 sea zones to the landing Palma
  # (AD79); the ferry AD79 - AE72 (distance 1) lies behind it, so a token in AE72 costs the zones and the ferry.
  describe 'a ferry behind a sea landing (#445)' do
    before do
      lnwr
      token!('X33', lnwr)
    end

    it 'counts the ferry after the landing together with the sea zones (§11.2.1)' do
      # Chris prices by weight (zone 2, ferry 1; token £20 a unit): 3 zones (£120) + 1 ferry (£20)

      expect(game.cross_water_token_fee(lnwr, hex('AE72').tile.city_towns.first)).to eq(140)
    end

    it 'does not count it for the landing itself' do

      expect(game.cross_water_token_fee(lnwr, hex('AD79').tile.city_towns.first)).to eq(120)
    end
  end

  # #445: two paid ferries one behind the other: AA20 - AB27 and AB27 - AF25 (each distance 1) meet in AB27.
  describe 'two ferries in a row (#445)' do
    let(:bend) do
      game.tiles.find { |t| !t.hex && t.exits.size == 2 && (0..5).any? { |r| t.rotate!(r) && t.exits.sort == [0, 1] } }
    end

    it 'charges both ferries for a tile behind the second' do
      lnwr
      lay!('AA20', '57', 5)
      token!('AA20', lnwr)
      skip 'no tile with the exits 0 and 1' unless bend
      bend.rotate!((0..5).find { |r| bend.rotate!(r) && bend.exits.sort == [0, 1] })
      hex('AB27').lay(bend)
      game.graph.clear


      expect(game.cross_water_tile_fee(lnwr, hex('AF25'), rotated('57', 3))).to eq(10) # two ferries, 5 each
    end
  end
end
