# frozen_string_literal: true

# EXTENSION (#581, #563 Task 9): rulebook 14.4 Barclay, Bevan, Barclay and Tritton. Chris' engine has the entity only,
# no effect. Patch engine/patches/0016-bbbt.patch. Rewritten from the legacy specs; the legacy enumerator examples
# (Oe::LegalActions) are not carried over: the enumerator is a later step (Task 4/5).

require_relative "../../engine/engine_helper"
require_relative "../../engine/g_18_oe/helpers"

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

    # #513: §6.1 (p. 17) removes the private at once; §14.4 (2) names no other condition (unlike (3)). Before
    # #513 this spec checked the removal at the end of the stock round.
    it 'removes the private at once, the reservation stays (also after the stock round)' do
      regional
      bbbt
      choose!('bbbt_custody:LNWR')
      reserved = regional_shares_for_sale.find { |s| game.bbbt_custody?(s) }

      expect(bbbt).to be_closed
      expect(player.companies).not_to include(bbbt)
      expect(game.bbbt_custody?(reserved)).to be(true)
      expect(game.bbbt_custody_blocks?(rival, reserved.to_bundle)).to be(true)

      game.bbbt_end_of_stock_round!

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

  # The special case kept from #78 (#513): while the owner's regional converts, a free choice from the major par
  # list (the re-par of the new major right at its float). The general re-par: barclay_bevan_repar_spec.rb.
  # #513 removed the spec 'is not offered as an ordinary private choice': §14.4 (1) offers it on any stock action.
  describe '(1) re-par at conversion' do
    let(:own) { start_regional!(game, 'LNWR', player) }

    before { allow(game).to receive(:major_phase?).and_return(true) }

    def start_conversion!
      act!(round, Engine::Action::Convert.new(own))
    end

    def finish_conversion!
      act!(round, Engine::Action::Pass.new(player))
      act!(round, Engine::Action::BuyShares.new(player, shares: own.ipo_shares.first, percent: 10))
    end

    it 'offers the six major par values while the regional converts' do
      own
      bbbt
      start_conversion!

      expect(step.actions(player)).to include('choose')
      expect(step.entity_choices(bbbt).keys.grep(/repar/)).to eq(%w[75 80 90 100 110 120].map { |v| "bbbt_repar:#{v}" })
    end

    it 'sets the chosen value instead of the letter mapping and closes the private' do
      own
      bbbt
      start_conversion!
      choose!('bbbt_repar:120')
      finish_conversion!

      expect(own.type).to eq(:major)
      expect(own.share_price.price).to eq(120)
      expect(own.par_price.price).to eq(120)
      expect(bbbt).to be_closed
    end

    it 'keeps the letter mapping when the owner does not use it' do
      own
      bbbt
      start_conversion!
      finish_conversion!

      expect(own.share_price.price).to eq(75)
      expect(bbbt).not_to be_closed
    end

    it 'leaves the treasury unchanged (only the president\'s share bought at the new par comes in)' do
      own
      bbbt
      cash = own.cash
      start_conversion!
      choose!('bbbt_repar:90')
      finish_conversion!

      expect(own.cash).to eq(cash + 90)
    end

    it 'is not offered to a player who does not own the private' do
      own
      give_company!(rival, game.company_by_id('BBBT'))
      start_conversion!

      expect(step.entity_choices(game.company_by_id('BBBT'))).to be_empty
    end

    it 'is not offered once the private was used for (2) or (3)' do
      own
      bbbt
      choose!('bbbt_protect:LNWR')
      step.instance_variable_set(:@private_action_used, false)
      start_conversion!

      expect(step.entity_choices(bbbt).keys.grep(/repar/)).to be_empty
    end

    it 'cannot be chosen with a value outside the major par list' do
      own
      bbbt
      start_conversion!

      expect { choose!('bbbt_repar:60') }.to raise_error(Engine::GameError)
    end
  end
end
