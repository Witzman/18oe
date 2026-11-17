# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE scenario building blocks (#365)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }

  it 'at_phase! advances to the named phase and rejects unknown names' do
    at_phase!(game, '3')
    expect(game.phase.name).to eq('3')
    expect { at_phase!(game, 'nope') }.to raise_error(ArgumentError)
  end

  it 'with_trains! gives the named trains, or the next card without names' do
    regional = start_regional!(game, 'LNWR', player)
    next_card = game.depot.upcoming.first
    expect(with_trains!(game, regional)).to eq([next_card])
    two_plus_two = with_trains!(game, regional, '2+2').first
    expect(regional.trains).to include(next_card, two_plus_two)
    expect { with_trains!(game, regional, 'no-such-train') }.to raise_error(ArgumentError)
  end

  it 'operating_regional! and operating_round_for! reach an OR with an operating regional' do
    regional = operating_regional!(game, 'LNWR', player)
    expect(regional.trains.size).to eq(1)
    round = operating_round_for!(game, 1, setup: true)
    expect(game.round).to be(round)
    expect(round).to be_operating
  end

  it 'lay_tile! puts a supply tile on a hex and rejects an unknown name' do
    hex = game.hexes.find { |h| h.tile.preprinted && h.tile.paths.empty? && h.tile.cities.empty? && h.tile.towns.empty? }
    tile = lay_tile!(game, hex.id, '8')
    expect(hex.tile).to be(tile)
    expect(tile.hex).to be(hex)
    expect(game.tiles).not_to include(tile) # #438: it left the supply, as in a real lay
    expect(lay_tile!(game, game.hexes.find { |h| h != hex && h.tile.preprinted && h.tile.paths.empty? && h.tile.cities.empty? && h.tile.towns.empty? }, '9', rotation: 2).rotation).to eq(2)
    expect { lay_tile!(game, hex, 'no-such-tile') }.to raise_error(ArgumentError)
  end

  it 'place_token! puts a free station of the corporation in the hex (#438)' do
    corp = game.corporation_by_id('LNWR')
    city = place_token!(game, 'AA20', corp)
    expect(city.hex.id).to eq('AA20')
    expect(city.tokens.compact.map(&:corporation)).to eq([corp])
    expect(corp.cash).to eq(0)
  end
end
