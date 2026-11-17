# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

describe 'G18OE Brandt and Brandau, Engineers (§14.9)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:owner) { game.players[0] }
  let(:other) { game.players[1] }
  let(:bbe) { give_company!(owner, game.company_by_id('BBE')) }
  let(:operator) { start_major!(game, 'LNWR', owner) }
  let(:round) do
    bbe
    operator
    fund!(game, operator, 500)
    r = enter_round!(game, game.operating_round(1))
    r.setup
    r
  end
  let(:track) { round_step(round, Engine::Game::G18OE::Step::Track) }
  let(:special) { round_step(round, Engine::Game::G18OE::Step::SpecialTrack) }
  let(:ability) { bbe.all_abilities.find { |a| a.type == :tile_lay } }

  before do
    round
    # the lay is checked against the RR's network; connectivity itself is not the subject here
    allow(track).to receive(:hex_neighbors) { |_entity, hex| hex.neighbors.keys }
  end

  def legal
    Oe::LegalActions.new(game)
  end

  def company_lays(hex_id)
    legal.call.select { |a| a.is_a?(Engine::Action::LayTile) && a.entity == bbe && a.hex.id == hex_id }
  end

  def place!(hex_id)
    act!(round, company_lays(hex_id).first)
  end

  it 'allows rough (hill, mountain) hexes without a city or metropolis only' do
    expect(ability.hexes).to include('R39', 'S38')
    expect(ability.hexes).not_to include('K64')
    expect(ability.hexes.map { |id| game.hex_by_id(id) }).to all(satisfy { |h| h.tile.cities.empty? && h.tile.color == :white })
  end

  it 'lays a yellow tile for free, spends a tile point and puts a token on the hex' do
    cash = operator.cash
    expect { place!('R39') }.to change(track, :points_used).by(1)

    expect(operator.cash).to eq(cash)
    expect(game.hex_by_id('R39').tile.color).to eq(:yellow)
    expect(game.bbe_token_hexes).to eq([game.hex_by_id('R39')])
    expect(game.hex_by_id('R39').tokens.map(&:corporation)).to eq([bbe])
    expect(ability.count).to eq(3)
  end

  it 'allows two tokens per OR' do
    place!('R39')
    place!('S38')

    expect(company_lays('Q50')).to be_empty
    expect(special.actions(bbe)).to eq([])
  end

  it 'offers nothing to the owner of another RR' do
    other_op = start_major!(game, 'CHN', other)
    game.minor_regional_order.delete(other_op)
    game.minor_regional_order.unshift(other_op)
    other_round = enter_round!(game, game.operating_round(1))
    other_round.setup

    expect(other_round.current_operator).to eq(other_op)
    expect(round_step(other_round, Engine::Game::G18OE::Step::SpecialTrack).actions(bbe)).to eq([])
  end

  it 'closes the marked hex to RRs of other players, not to the owner\'s' do
    place!('R39')
    other_op = start_major!(game, 'CHN', other)

    expect(game.bbe_blocked_for?(operator)).to be(false)
    expect(game.bbe_blocked_for?(other_op)).to be(true)
    expect(game.graph_skip_paths(operator)).to be_nil
    expect(game.graph_skip_paths(other_op).keys).to eq(game.hex_by_id('R39').tile.paths)
  end

  it 'turns the certificate face down after the last token and removes it with the last token' do
    chosen = ability
    4.times do |i|
      chosen.use!
      game.bbe_place_token!(game.hex_by_id(chosen.hexes[i]), bbe)
    end

    expect(game.face_down_private?(bbe)).to be(true)
    expect(game.bbe_token_hexes.size).to eq(4)
    game.bbe_token_hexes.dup.each { |hex| game.bbe_remove_token!(hex) }

    expect(bbe.closed?).to be(true)
    expect(game.bbe_token_hexes).to be_empty
  end

  describe 'removal by another RR' do
    let(:other_op) { start_major!(game, 'CHN', other) }
    let(:other_round) do
      fund!(game, other_op, 500)
      game.minor_regional_order.delete(other_op)
      game.minor_regional_order.unshift(other_op)
      r = enter_round!(game, game.operating_round(1))
      r.setup
      r
    end

    before do
      place!('R39')
      other_round
    end

    it 'costs the original terrain price and one tile point, and lays no track' do
      removal = legal.call.find { |a| a.is_a?(Engine::Action::RemoveHexToken) }
      expect(removal.hex.id).to eq('R39')
      step = round_step(other_round, Engine::Game::G18OE::Step::Track)
      cash = other_op.cash

      act!(other_round, removal)

      expect(cash - other_op.cash).to eq(30)
      expect(step.points_used).to eq(1)
      expect(game.bbe_token_hexes).to be_empty
      expect(game.hex_by_id('R39').tile.color).to eq(:yellow)
    end

    it 'is not offered to the token owner\'s own RRs' do
      expect(round_step(round, Engine::Game::G18OE::Step::Track).bbe_removable_hexes(operator)).to eq([])
    end

    it 'costs a national only the tile point' do
      step = round_step(other_round, Engine::Game::G18OE::Step::Track)
      national = Struct.new(:type).new(:national)

      expect(step.bbe_removal_money(national, game.hex_by_id('R39'))).to eq(0)
    end
  end
end
