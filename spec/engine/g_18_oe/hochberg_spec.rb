# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

describe 'G18OE Hochberg Mining and Lumber Co. (§14.8)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:owner) { game.players[0] }
  let(:other) { game.players[1] }
  let(:hmlc) { give_company!(owner, game.company_by_id('HMLC')) }
  let(:operator) { start_major!(game, 'LNWR', owner) }
  let(:round) do
    hmlc
    operator
    r = enter_round!(game, game.operating_round(1))
    r.setup
    r
  end

  def placements
    Oe::LegalActions.new(game).call.select { |a| a.is_a?(Engine::Action::Choose) && a.entity == hmlc }
  end

  it 'allows rough hexes costing at least 45, with no city, metropolis or two towns' do
    hexes = game.hochberg_hexes

    expect(hexes.map(&:id)).to include('S38', 'U38')
    expect(hexes.map(&:id)).not_to include('R39', 'K64')
    expect(hexes).to all(satisfy { |h| h.tile.cities.empty? && h.tile.towns.size <= 1 && h.original_tile.upgrades.sum(&:cost) >= 45 })
  end

  it 'offers the token to the owner while an RR of theirs lays track, and places it' do
    round
    choose = placements.find { |a| a.target.id == 'S38' }
    expect(choose).not_to be_nil

    act!(round, choose)

    expect(game.hochberg_hex.id).to eq('S38')
    expect(game.face_down_private?(hmlc)).to be(true)
    expect(hmlc.revenue).to eq(0)
    expect(placements).to be_empty
  end

  it 'accepts every placement the enumerator offers (#510)' do
    round
    offered = placements

    expect(offered).not_to be_empty
    expect { act!(round, offered.last) }.not_to raise_error
    expect(game.hochberg_hex).to eq(offered.last.target)
  end

  it 'offers nothing to a player who does not control the operating RR' do
    start_major!(game, 'CHN', other)
    other_op = game.corporation_by_id('CHN')
    game.minor_regional_order.delete(other_op)
    game.minor_regional_order.unshift(other_op)
    hmlc
    r = enter_round!(game, game.operating_round(1))
    r.setup

    expect(r.current_operator).to eq(other_op)
    expect(placements).to be_empty
  end

  it 'refuses a hex that does not qualify' do
    round
    action = Engine::Action::Choose.new(hmlc, choice: 'hochberg_token', target: game.hex_by_id('R39'))

    expect { act!(round, action) }.to raise_error(Engine::GameError, /cannot take the token/)
  end

  it 'pays by phase' do
    [[2, 10], [3, 20], [4, 20], [5, 40], [6, 40], [7, 60], [8, 60]].each do |phase, pay|
      at_phase!(game, phase.to_s)
      expect(game.hochberg_token_revenue).to eq(pay)
    end
  end

  it 'adds the token to routes through its hex for the owner\'s RRs only and drops the town it replaced' do
    round
    hex = game.hex_by_id('S38')
    game.hochberg_place_token!(hex)
    owner_train = Struct.new(:owner).new(operator)
    other_train = Struct.new(:owner).new(Struct.new(:owner).new(other))
    path = Struct.new(:hex)
    route = ->(train) { Struct.new(:paths, :train, :phase).new([path.new(hex)], train, game.phase) }

    expect(game.hochberg_revenue_change(route.call(owner_train), [])).to eq(10)
    expect(game.hochberg_revenue_change(route.call(other_train), [])).to eq(0)
    expect(game.hochberg_revenue_change(Struct.new(:paths, :train, :phase).new([], owner_train, game.phase), [])).to eq(0)
  end

  it 'drops the revenue of the town the token replaces, for every RR' do
    round
    hex = game.hex_by_id('R51')
    expect(game.hochberg_hexes).to include(hex)
    game.hochberg_place_token!(hex)
    town = Struct.new(:hex) do
      def town? = true
      def route_revenue(_phase, _train) = 10
    end.new(hex)
    train = Struct.new(:owner).new(Struct.new(:owner).new(other))
    route = Struct.new(:paths, :train, :phase).new([Struct.new(:hex).new(hex)], train, game.phase)

    expect(game.hochberg_revenue_change(route, [town])).to eq(-10)
  end
end
