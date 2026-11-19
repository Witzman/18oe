# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# #78 (§14.4), first part: abilities (2) custodianship and (3) protection against DOWN, used on the owner's own turn.
describe 'G18OE Barclay, Bevan, Barclay and Tritton (§14.4)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game) }
  let(:step) { round.active_step }
  let(:player) { round.current_entity }
  let(:rival) { game.players.find { |p| p != player } }
  let(:bbbt) { give_company!(player, game.company_by_id('BBBT')) }
  let(:regional) { start_regional!(game, 'LNWR', rival) }

  def choose!(choice, company = bbbt)
    act!(round, Engine::Action::Choose.new(player, choice: choice, target: company))
  end

  def regional_shares_for_sale
    regional.ipo_shares.reject(&:president)
  end

  describe '(2) custodianship' do
    it 'is offered for a regional while both secondary shares are in its treasury' do
      regional
      bbbt

      expect(step.entity_choices(bbbt).keys).to include('bbbt_custody:LNWR')
    end

    it 'is not offered for a regional once one secondary share is gone' do
      regional
      game.share_pool.buy_shares(rival, regional.ipo_shares.reject(&:president).first)
      bbbt

      expect(step.entity_choices(bbbt).keys).not_to include('bbbt_custody:LNWR')
    end

    it 'reserves a share for the owner: another player may not buy it, the owner may' do
      regional
      bbbt
      choose!('bbbt_custody:LNWR')
      reserved = regional_shares_for_sale.find { |s| game.bbbt_custody?(s) }

      expect(reserved).not_to be_nil
      expect(game.bbbt_custody_blocks?(rival, reserved.to_bundle)).to be(true)
      expect(game.bbbt_custody_blocks?(player, reserved.to_bundle)).to be(false)
    end

    it 'does not block the other shares' do
      regional
      bbbt
      choose!('bbbt_custody:LNWR')
      free = regional_shares_for_sale.reject { |s| game.bbbt_custody?(s) }

      expect(free).not_to be_empty
      expect(free.map { |s| game.bbbt_custody_blocks?(rival, s.to_bundle) }).to all(be(false))
    end

    it 'uses up the private action of the turn and the private (once)' do
      regional
      bbbt
      choose!('bbbt_custody:LNWR')

      expect(step.entity_choices(bbbt)).to eq({})
    end

    it 'closes the private at the end of the stock round, the reservation stays' do
      regional
      bbbt
      choose!('bbbt_custody:LNWR')
      reserved = regional_shares_for_sale.find { |s| game.bbbt_custody?(s) }

      game.bbbt_end_of_stock_round!

      expect(bbbt).to be_closed
      expect(game.bbbt_custody?(reserved)).to be(true)
    end

    it 'ends when the share has been bought' do
      regional
      bbbt
      choose!('bbbt_custody:LNWR')
      reserved = regional_shares_for_sale.find { |s| game.bbbt_custody?(s) }
      fund!(game, player)
      game.share_pool.buy_shares(player, reserved)

      expect(game.bbbt_custody?(reserved)).to be(false)
    end
  end

  describe '(3) protection against DOWN' do
    def sell_one_share_of(corporation, seller)
      share = corporation.shares_of(corporation).first
      bundle = Engine::ShareBundle.new(seller.shares_of(corporation).reject(&:president).first || share)
      game.sell_shares_and_change_price(bundle)
    end

    before do
      regional
      take_treasury_shares!(game, rival, regional, 1)
    end

    it 'is offered for any RR, also a foreign one' do
      bbbt

      expect(step.entity_choices(bbbt).keys).to include('bbbt_protect:LNWR')
    end

    it 'keeps the share value marker in place when a share is sold' do
      bbbt
      choose!('bbbt_protect:LNWR')
      before = regional.share_price.price

      sell_one_share_of(regional, rival)

      expect(regional.share_price.price).to eq(before)
    end

    it 'lets other RRs fall as usual' do
      bbbt
      other = start_regional!(game, 'GWR', rival)
      take_treasury_shares!(game, rival, other, 1)
      choose!('bbbt_protect:LNWR')
      before = other.share_price.price

      sell_one_share_of(other, rival)

      expect(other.share_price.price).to be < before
    end

    it 'falls as usual without the protection' do
      before = regional.share_price.price

      sell_one_share_of(regional, rival)

      expect(regional.share_price.price).to be < before
    end

    it 'ends with the stock round and the private leaves the game' do
      bbbt
      choose!('bbbt_protect:LNWR')

      game.bbbt_end_of_stock_round!

      expect(game.bbbt_protected?(regional)).to be(false)
      expect(bbbt).to be_closed
    end
  end

  it 'is enumerated for the owner, and every offered action is accepted' do
    regional
    bbbt
    choices = Oe::LegalActions.new(game).call.select { |a| a.is_a?(Engine::Action::Choose) && a.target == bbbt }

    expect(choices.map(&:choice)).to include('bbbt_custody:LNWR', 'bbbt_protect:LNWR')
    expect { act!(round, choices.select { |a| a.choice.start_with?('bbbt_') }.sample) }.not_to raise_error
  end
end
