# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #56 part 2, rewritten on Chris' fee API in the triage (#563 Task 8): a port authority marker takes two sea zones and
# ferry distance off the cost of laying track or a token over water (§11.1.6, §11.2.1, §11.3.5). Port tokens and
# Minor H do not change it.
# Old API -> Chris: cross_water_token_cost(..).zones/.ferries/.areas -> cross_water_token_fee in pounds (zone = 2 units
# of £20 = £40, ferry distance = 1 unit = £20); @port_authority_owners[corp] = area -> @port_authorities[corp] = [sea].
# 'knows the water areas of the crossing' has no counterpart: Chris keeps the sea per edge inside SeaConnectivity.
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

  def own!(sea)
    game.instance_variable_get(:@port_authorities)[lnwr] = [sea]
    game.graph.clear
  end

  def fee(hex_id)
    game.cross_water_token_fee(lnwr, hex(hex_id).tile.city_towns.first)
  end

  describe 'on a real crossing (X33 to the landing AD79: 3 sea zones, Mediterranean)' do
    before { token!('X33', lnwr) }

    it 'charges the three zones in full without a marker' do
      expect(fee('AD79')).to eq(120)
    end

    it 'takes two zones off for the marker of the crossing\'s area' do
      own!(:mediterranean)

      expect(fee('AD79')).to eq(40)
    end

    it 'takes nothing off for the marker of the other area' do
      own!(:north_sea)

      expect(fee('AD79')).to eq(120)
    end

    it 'takes the two units off the zones first, then the ferry behind the landing' do
      own!(:mediterranean)

      expect(fee('AE72')).to eq(40 + 20) # one zone left, the ferry AD79 - AE72 in full
    end

    it 'prices the reduced crossing (£40 a zone for a token)' do
      own!(:mediterranean)

      expect(fee('AD79')).to eq(40)
    end
  end
end
