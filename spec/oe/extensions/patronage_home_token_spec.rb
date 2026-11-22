# frozen_string_literal: true

require_relative "../../engine/engine_helper"
require_relative "../../engine/g_18_oe/helpers"

# EXTENSION (decision open, #557), red until decided: rulebook 9.1 says the minor's treasury receives the lowest
# payout of the patronage tile when its home token lands on it; Chris' engine removes the tile without payment
# ("designer ruling over 9.1", diff-A A2). Patch if kept: Step::HomeToken pays Game#fulfill_patronage!(lowest: true).
describe "G18OE patronage on a minor's home token (extension)" do
  include G18OESpecHelpers

  let(:game) { new_game }

  def patronage(game, hex_id)
    game.hex_by_id(hex_id).tile.patronage
  end

  context 'when a minor places its home token on a patronage city (§9.1)' do
    it 'fulfills the tile at once: the treasury receives the lowest payout and the tile is removed' do
      round = enter_round!(game, game.stock_round)
      player = round.current_entity
      minor = game.corporation_by_id('A')
      give_company!(player, game.company_by_id('A'))
      fund!(game, minor, 120)
      game.place_patronage_tile!('V27')
      price = round.active_step.get_par_prices(player, minor).first
      act!(round, Engine::Action::Par.new(player, corporation: minor, share_price: price))
      city = game.hex_by_id('V27').tile.cities.first
      bank = game.bank.cash

      act!(round, Engine::Action::PlaceToken.new(minor, city: city, slot: 0))

      # Toulouse pays 20/30/40/50 by track colour; the lowest (20) is paid whatever the phase, the token costs 20.
      expect(minor.cash).to eq(120)
      expect(game.bank.cash).to eq(bank)
      expect(patronage(game, 'V27')).to be_nil
      expect(game.log.map(&:message)).to include('A fulfills the Toulouse patronage tile and receives £20')
      expect { game.fulfill_patronage!(minor, game.hex_by_id('V27')) }.not_to(change { minor.cash })
    end
  end
end
