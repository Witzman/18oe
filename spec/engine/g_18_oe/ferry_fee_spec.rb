# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #61: the ferry part of the cross-water fees. A tile (§11.1.6) or a token (§11.2.1) the hypothetical train reaches
# over a ferry costs £5 (tile) or £20 (token) times the ferry's distance; the sea zone part is in cross_water_spec.
# Port categories do not change the fee. A ferry of distance 0 costs nothing.
describe 'G18OE ferry fees for track and tokens (§11.1.6, §11.2.1)' do
  include G18OESpecHelpers

  let(:game) { new_game }
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
      expect(game.cross_water_track_fee(lnwr, hex('H55'), rotated('57', 4))).to eq(5)
    end

    it 'charges £20 for a token on the far shore (§11.2.1)' do
      lay!('H55', '57', 4)

      expect(game.cross_water_token_fee(lnwr, hex('H55').tile.cities.first)).to eq(20)
    end

    it 'charges nothing for a tile on the near shore' do
      expect(game.cross_water_track_fee(lnwr, hex('K60'), rotated('57', 2))).to eq(0)
    end

    it 'charges nothing to a national (§11.1.5)' do
      lnwr.type = :national

      expect(game.cross_water_track_fee(lnwr, hex('H55'), rotated('57', 4))).to eq(0)
    end

    it 'pays the ferry with the tile and says so in the log (§11.1.6)' do
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

      step.lay_tile_action(Engine::Action::LayTile.new(lnwr, tile: tile, hex: hex('H55'), rotation: rotation))

      messages = game.log.map(&:message)
      expect(messages).to include("LNWR pays £5 for 1 ferry crossed to the new track (§11.1.6)")
      expect(before - lnwr.cash).to be >= 5
    end

    it 'pays the ferry with the token and says so in the log (§11.2.1)' do
      lay!('H55', '57', 4)
      cash!(lnwr, 1000)
      token = lnwr.next_token
      price = token.price

      token_step.place_token(lnwr, hex('H55').tile.cities.first, token)

      expect(lnwr.cash).to eq(1000 - price - 20)
      expect(game.log.map(&:message)).to include('LNWR pays £20 for 1 ferry crossed to the token (§11.2.1)')
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
      expect(game.cross_water_track_fee(lnwr, hex('Z41'), rotated('57', 2))).to eq(0)
      lay!('Z41', '57', 2)

      expect(game.cross_water_token_fee(lnwr, hex('Z41').tile.cities.first)).to eq(0)
    end
  end
end
