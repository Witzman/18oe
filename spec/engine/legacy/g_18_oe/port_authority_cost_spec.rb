# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #56 part 2: a port authority marker takes two sea zones and ferry distance off the cost of laying track or a
# token over water (§11.1.6, §11.2.1, §11.3.5). Port tokens and Minor H do not change it.
describe 'G18OE port authority and cross-water costs (§11.3.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let!(:lnwr) { start_major!(game, 'LNWR', game.players.first) }

  def hex(hex_id)
    game.hex_by_id(hex_id)
  end

  def token!(hex_id, corporation)
    city = hex(hex_id).tile.cities.first
    city.place_token(corporation, corporation.next_token, free: true, check_tokenable: false)
    game.graph.clear
  end

  def own!(area)
    game.instance_variable_get(:@port_authority_owners)[lnwr] = area
  end

  def cost(hex_id)
    game.cross_water_token_cost(lnwr, hex(hex_id).tile.city_towns.first)
  end

  describe 'on a real crossing (X33 to the landing AD79: 3 sea zones, Mediterranean)' do
    before { token!('X33', lnwr) }

    it 'knows the water areas of the crossing' do
      expect(cost('AD79').areas).to eq([:mediterranean])
    end

    it 'takes two zones off for the marker of the crossing\'s area' do
      own!(:mediterranean)
      expect(cost('AD79').zones).to eq(1)
    end

    it 'takes nothing off for the marker of the other area' do
      own!(:north_sea)
      expect(cost('AD79').zones).to eq(3)
    end

    it 'takes the two units off the zones first, then the ferry behind the landing' do
      own!(:mediterranean)
      reduced = cost('AE72')
      expect([reduced.ferries, reduced.zones]).to eq([1, 1])
    end

    it 'prices the reduced crossing (£40 a zone for a token)' do
      own!(:mediterranean)
      expect(game.cross_water_fee_of(cost('AD79'), :token)).to eq(40)
    end
  end

  describe 'without a marker' do
    it 'changes nothing' do
      token!('X33', lnwr)
      expect(cost('AD79').zones).to eq(3)
    end
  end
end
