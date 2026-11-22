# frozen_string_literal: true

# EXTENSION (#563 Task 8/9): red on Chris' engine until the patch for BBBT custody window on a share purchase (Step::CustodyShare) exists. Source of the old code: main:lib/engine/game/g_18_oe/step/custody_share.rb.
# Triage: notes/rueckport-differenz/spec-triage-B.md. Do not delete; Task 9 turns it green.

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# #514 (§14.4 (2), PDF p. 43), owner's decision A: custodianship "may be exercised at any time during a SR,
# including at the moment another player is purchasing a share of stock in the owning player's RR". The purchase
# waits in Step::CustodyShare (pattern Step::ProtectShare, #476). On `custody` the share is reserved and the buyer
# keeps the stock action (assumption, as §8.4 p. 20: "does not forfeit their stock action"); `pass` completes it.
describe 'G18OE Barclay, Bevan, Barclay and Tritton: window at a foreign purchase (§14.4 (2))' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game) }
  let(:buyer) { round.current_entity }
  let(:owner) { game.players.find { |p| p != buyer } }
  let(:third) { game.players.find { |p| p != buyer && p != owner } }
  let(:major) { start_major!(game, 'LNWR', owner) }
  let(:bbbt) { give_company!(owner, game.company_by_id('BBBT')) }

  def window_step
    round.steps.find { |step| step.is_a?(Engine::Game::G18OE::Step::CustodyShare) }
  end

  def buy_action(corporation = major, share = corporation.ipo_shares.reject(&:president).first)
    Engine::Action::BuyShares.new(buyer, shares: share, percent: share.percent)
  end

  def buy!(corporation = major)
    act!(round, buy_action(corporation))
  end

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    round
    fund!(game, buyer)
  end

  context 'with a major of the owner' do
    before do
      major
      bbbt
    end

    it 'holds the purchase and asks the owner of the private' do
      buy!

      expect(round.active_step).to be(window_step)
      expect(round.active_entities).to eq([owner])
      expect(buyer.shares_of(major)).to be_empty
    end

    it 'on pass completes the purchase' do
      buy!
      act!(round, Engine::Action::Pass.new(owner))

      expect(buyer.shares_of(major).size).to eq(1)
      expect(game.bbbt_exercised?).to be(false)
      expect(round.active_step).not_to be(window_step)
    end

    it 'on custody reserves the share, the buyer cannot buy it and keeps the stock action' do
      share = major.ipo_shares.reject(&:president).first
      buy!
      act!(round, Engine::Action::Choose.new(owner, choice: 'custody'))

      expect(game.bbbt_custody?(share)).to be(true)
      expect(game.bbbt_exercised?).to be(true)
      expect(buyer.shares_of(major)).to be_empty
      expect(round.active_entities).to eq([buyer])
      expect(round.active_step.actions(buyer)).to include('buy_shares')
      expect { act!(round, Engine::Action::BuyShares.new(buyer, shares: share, percent: share.percent)) }
        .to raise_error(Engine::GameError)
    end

    it 'lets the buyer buy another share after the custody' do
      buy!
      act!(round, Engine::Action::Choose.new(owner, choice: 'custody'))
      free = major.ipo_shares.reject { |s| s.president || game.bbbt_custody?(s) }.first

      expect { act!(round, Engine::Action::BuyShares.new(buyer, shares: free, percent: free.percent)) }.not_to raise_error
      expect(buyer.shares_of(major)).to eq([free])
    end

    it 'does not ask once the private is used up' do
      game.instance_variable_set(:@bbbt_used, true)
      buy!

      expect(round.active_step).not_to be(window_step)
      expect(buyer.shares_of(major).size).to eq(1)
    end

    it 'does not ask for a purchase from the Open Market' do
      take_treasury_shares!(game, third, major, 1)
      pool_share = third.shares_of(major).first
      game.share_pool.sell_shares(pool_share.to_bundle)
      act!(round, Engine::Action::BuyShares.new(buyer, shares: pool_share, percent: pool_share.percent))

      expect(round.active_step).not_to be(window_step)
    end

    it 'is enumerated for the owner as choose and pass, and both are accepted' do
      buy!
      actions = Oe::LegalActions.new(game).call

      expect(actions.map(&:entity).uniq).to eq([owner])
      expect(actions.map(&:class)).to contain_exactly(Engine::Action::Choose, Engine::Action::Pass)
      expect { act!(round, actions.find { |a| a.is_a?(Engine::Action::Choose) }) }.not_to raise_error
    end

    it 'accepts the offered pass too' do
      buy!
      pass = Oe::LegalActions.new(game).call.find { |a| a.is_a?(Engine::Action::Pass) }

      expect { act!(round, pass) }.not_to raise_error
      expect(buyer.shares_of(major).size).to eq(1)
    end
  end

  it 'does not ask for a RR of another player' do
    foreign = start_major!(game, 'LNWR', third)
    bbbt
    buy!(foreign)

    expect(round.active_step).not_to be(window_step)
  end

  it 'does not ask for a purchase by the owner of the private' do
    major
    give_company!(buyer, game.company_by_id('BBBT'))
    buy!

    expect(round.active_step).not_to be(window_step)
  end

  describe 'a regional of the owner' do
    let(:regional) { start_regional!(game, 'GWR', owner) }

    before { bbbt }

    it 'asks while both secondary shares are in its treasury' do
      buy!(regional)

      expect(round.active_step).to be(window_step)
    end

    it 'follows a declined reservation (§8.4) once, then the purchase completes' do
      game.instance_variable_set(:@turn, 1)
      buy!(regional)
      reserve_step = round.steps.find { |step| step.is_a?(Engine::Game::G18OE::Step::ReserveShare) }
      expect(round.active_step).to be(reserve_step)

      act!(round, Engine::Action::Pass.new(owner))
      expect(round.active_step).to be(window_step)

      act!(round, Engine::Action::Pass.new(owner))
      expect(round.active_step).not_to be(window_step)
      expect(round.active_step).not_to be(reserve_step)
      expect(buyer.shares_of(regional).size).to eq(1)
    end

    it 'does not ask once one secondary share is gone (§14.4 (2))' do
      take_treasury_shares!(game, third, regional, 1)
      buy!(regional)

      expect(round.active_step).not_to be(window_step)
      expect(buyer.shares_of(regional).size).to eq(1)
    end
  end
end
