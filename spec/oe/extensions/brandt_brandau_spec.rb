# frozen_string_literal: true

# EXTENSION SPEC (#582, #563 Task 9): rulebook 14.9 Brandt & Brandau, Engineers and 11.3.10. Chris' engine has the private's
# text only. Patch engine/patches/0017-brandt-brandau.patch: a tile_lay ability (4 free yellow lays on rough hexes, two per OR),
# G18OE::Step::SpecialTrack, a hex token that closes the lay's track to RRs of other players (graph_skip_paths, route check,
# national revenue) and removal by another RR in its Track step (RemoveHexToken, tile points and terrain cost).
# The move enumerator is covered only as far as 'move enumerator' below (carried over from the old legacy spec); the view is not.

require_relative '../../engine/engine_helper'
require_relative '../../engine/g_18_oe/helpers'
require 'oe/legal_actions'

describe 'G18OE Brandt and Brandau, Engineers (RB 14.9, 11.3.10)' do
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

  # The first yellow tile of the supply that fits `hex_id`, as the lay action of the private.
  def company_lay(hex_id)
    hex = game.hex_by_id(hex_id)
    special.potential_tiles(bbe, hex).each do |tile|
      rotation = special.legal_tile_rotations(bbe, hex, tile).first
      return Engine::Action::LayTile.new(bbe, tile: tile, hex: hex, rotation: rotation) if rotation
    end
    raise "no lay for #{hex_id}"
  end

  def place!(hex_id)
    act!(round, company_lay(hex_id))
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

    expect(special.available_hex(bbe, game.hex_by_id('Q50'))).to be_nil
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

  describe 'blocking the connection' do
    let(:other_op) { start_major!(game, 'CHN', other) }

    before { place!('R39') }

    it 'closes the marked hex to RRs of other players, not to the owner\'s' do
      expect(game.bbe_blocked_for?(operator)).to be(false)
      expect(game.bbe_blocked_for?(other_op)).to be(true)
      expect(game.graph_skip_paths(operator)).to be_nil
      expect(game.graph_skip_paths(other_op).keys).to eq(game.hex_by_id('R39').tile.paths)
    end

    it 'rejects a route over the marked hex for another player\'s RR, and takes it for the owner\'s' do
      route = instance_double(Engine::Route, paths: game.hex_by_id('R39').tile.paths)
      allow(game).to receive(:land_stretches).and_return([])
      allow(route).to receive(:connection_data).and_return([])

      expect { game.check_connected(route, other_op) }.to raise_error(Engine::GameError, /Brandt and Brandau/)
      expect { game.check_connected(route, operator) }.not_to raise_error
    end

    it 'does not count the marked hex as a link for a national\'s revenue' do
      national = Struct.new(:owner, :trains).new(other, [])
      revenue = Engine::Game::G18OE::NationalRevenue.new(game, national)
      node = game.lille_city
      skip = game.graph_skip_paths(national)

      expect(skip).not_to be_nil
      expect(node).to receive(:walk).with(hash_including(skip_paths: skip)).and_return(nil)
      revenue.send(:linked?, node)
    end
  end

  it 'turns the certificate face down after the last token and removes it with the last token' do
    4.times do |i|
      ability.use!
      game.bbe_place_token!(game.hex_by_id(ability.hexes[i]), bbe)
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
    let(:other_track) { round_step(other_round, Engine::Game::G18OE::Step::Track) }

    before do
      place!('R39')
      other_round
    end

    it 'costs the original terrain price and one tile point, and lays no track' do
      expect(other_track.actions(other_op)).to include('remove_hex_token')
      cash = other_op.cash

      act!(other_round, Engine::Action::RemoveHexToken.new(other_op, hex: game.hex_by_id('R39')))

      expect(cash - other_op.cash).to eq(30)
      expect(other_track.points_used).to eq(1)
      expect(game.bbe_token_hexes).to be_empty
      expect(game.hex_by_id('R39').tile.color).to eq(:yellow)
    end

    it 'is not offered to the token owner\'s own RRs' do
      expect(track.bbe_removable_hexes(operator)).to eq([])
    end

    it 'costs a national only the tile point' do
      national = Struct.new(:type) { def corporation? = true }.new(:national)

      expect(other_track.bbe_removal_money(national, game.hex_by_id('R39'))).to eq(0)
    end
  end

  # Carried over from spec/engine/legacy/g_18_oe/brandt_brandau_spec.rb (#563): what the wrapper's enumerator offers.
  describe 'move enumerator (Oe::LegalActions)' do
    def legal
      Oe::LegalActions.new(game)
    end

    def company_lays(hex_id)
      legal.call.select { |a| a.is_a?(Engine::Action::LayTile) && a.entity == bbe && a.hex.id == hex_id }
    end

    it 'offers the private\'s lay on a rough hex, and no third hex after two tokens in the OR' do
      expect(company_lays('R39')).not_to be_empty
      act!(round, company_lays('R39').first)
      act!(round, company_lays('S38').first)

      expect(company_lays('Q50')).to be_empty
    end

    it 'offers the removal of the token to the RR of another player' do
      pending('Oe::LegalActions does not offer RemoveHexToken yet (finding #563: wrapper, not engine)')
      place!('R39')
      other_op = start_major!(game, 'CHN', other)
      fund!(game, other_op, 500)
      game.minor_regional_order.delete(other_op)
      game.minor_regional_order.unshift(other_op)
      enter_round!(game, game.operating_round(1)).setup

      removal = legal.call.find { |a| a.is_a?(Engine::Action::RemoveHexToken) }
      expect(removal&.hex&.id).to eq('R39')
    end
  end
end
