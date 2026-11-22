# frozen_string_literal: true

# EXTENSION (#563 Task 8/9): red on Chris' engine until the patch for buyback of an insolvent charter, #576 exists. Source of the old code: main:lib/engine/game/g_18_oe/step/buy_sell_par_shares.rb.
# Triage: notes/rueckport-differenz/spec-triage-B.md. Do not delete; Task 9 turns it green.

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'
require 'oe/view'

# §11.6.5 step 4 (RB l. 4709-4710, 4613-4618): in a SR the Open-Market charter of an
# insolvent minor, or the president's certificate of an insolvent regional, may be bought
# as a stock action for its face value plus the difference between the RR's treasury and
# the price of the reserved 2+2. The par value of a regional stays (#353).
# ASSUMPTION (#54 plan, assumption 2): the price is paid to the bank, which financed the gap.
# ASSUMPTION (#54 plan, assumption 5): an RR nobody buys back stays in the Open Market and
# does not operate; it can be bought back in any later SR, the Consolidation round included
# (§10.6 allows "the usual SR actions"), the rulebook says nothing more about it.
describe 'G18OE buying back an insolvent minor or regional (§11.6.5 step 4)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:president) { game.players.first }
  let(:buyer) { game.players[1] }

  def go_insolvent!(corporation, rr_cash:, president_cash:)
    enter_round!(game, game.operating_round(1))
    step = round_step(game.round, Engine::Game::G18OE::Step::BuyTrain)
    corporation.set_cash(rr_cash, game.bank)
    president.set_cash(president_cash, game.bank)
    step.skip!
    corporation
  end

  def stock_round_for!(player)
    round = stock_round!(game)
    pass_until!(round, player)
    round
  end

  def sr_step(round)
    round_step(round, Engine::Game::G18OE::Step::BuySellParShares)
  end

  def buy_back!(round, player, corporation)
    bundle = corporation.presidents_share.to_bundle
    act!(round, Engine::Action::BuyShares.new(player, shares: bundle.shares, percent: bundle.percent))
  end

  context 'with an insolvent minor' do
    let(:minor) { go_insolvent!(start_minor!(game, 'K', president, 'RU'), rr_cash: 30, president_cash: 40) }

    it 'is marked insolvent and priced at £120 plus (2+2 minus treasury)' do
      minor
      expect(game.insolvent_corporations).to eq([minor])
      expect(minor.cash).to eq(70)
      expect(game.insolvent_buyback_price(minor)).to eq(120 + (100 - 70))
    end

    it 'offers the charter to a player in a SR and the enumerator lists it' do
      minor
      round = stock_round_for!(buyer)
      bundle = minor.presidents_share.to_bundle

      expect(sr_step(round).can_buy?(buyer, bundle)).to be(true)
      expect(sr_step(round).actions(buyer)).to include('buy_shares')
      buys = Oe::LegalActions.new(game).call.select { |a| a.is_a?(Engine::Action::BuyShares) }
      expect(buys.map { |a| a.bundle.corporation }).to include(minor)
    end

    it 'charges face value plus the gap to the bank and ends the receivership' do
      minor
      round = stock_round_for!(buyer)
      fund!(game, buyer, 500)
      buyer_before = buyer.cash
      bank_before = game.bank.cash

      buy_back!(round, buyer, minor)

      expect(buyer.cash).to eq(buyer_before - 150)
      expect(game.bank.cash).to eq(bank_before + 150)
      expect(minor.cash).to eq(70)
      expect(minor.owner).to eq(buyer)
      expect(minor.presidents_share.owner).to eq(buyer)
      expect(minor.receivership?).to be(false)
      expect(game.insolvent_corporations).to be_empty
      expect(enter_round!(game, game.operating_round(2)).skip_entity?(minor)).to be(false)
    end

    it 'shows the buyback price in the view (#47 stock context)' do
      minor
      stock_round_for!(buyer)
      fund!(game, buyer, 500)
      view = Oe::View.render(game, viewer: buyer.id, log: nil)
      offer = view[:prompt][:context][:stock][:bundles].find do |b|
        b[:type] == 'buy_shares' && b[:corporation] == minor.id
      end

      expect(offer[:price]).to eq(150)
    end

    it 'is one stock action: nothing else may be bought afterwards' do
      minor
      round = stock_round_for!(buyer)
      fund!(game, buyer, 1000)
      buy_back!(round, buyer, minor)

      expect(sr_step(round).actions(buyer)).not_to include('buy_shares')
    end

    it 'is refused without enough cash' do
      minor
      round = stock_round_for!(buyer)
      buyer.set_cash(149, game.bank)

      expect(sr_step(round).can_buy?(buyer, minor.presidents_share.to_bundle)).to be(false)
    end

    it 'is refused at the certificate limit' do
      minor
      round = stock_round_for!(buyer)
      fund!(game, buyer, 500)
      allow(game).to receive(:cert_limit).and_return(game.num_certs(buyer))

      expect(sr_step(round).can_buy?(buyer, minor.presidents_share.to_bundle)).to be(false)
    end

    it 'may be bought back by the former president as well' do
      minor
      round = stock_round_for!(president)
      fund!(game, president, 500)

      expect(sr_step(round).can_buy?(president, minor.presidents_share.to_bundle)).to be(true)
    end

    it 'costs only face value when the treasury already covers the 2+2' do
      minor
      minor.set_cash(130, game.bank)

      expect(game.insolvent_buyback_price(minor)).to eq(120)
    end
  end

  context 'with an insolvent regional' do
    let(:regional) do
      go_insolvent!(start_regional!(game, 'LNWR', president, par: 60), rr_cash: 10, president_cash: 5)
    end

    it 'charges 2 x par plus the gap and keeps the par value' do
      regional
      par = regional.par_price
      round = stock_round_for!(buyer)
      fund!(game, buyer, 500)
      buyer_before = buyer.cash

      expect(game.insolvent_buyback_price(regional)).to eq(120 + (100 - 15))
      buy_back!(round, buyer, regional)

      expect(buyer.cash).to eq(buyer_before - 205)
      expect(regional.owner).to eq(buyer)
      expect(regional.presidents_share.owner).to eq(buyer)
      expect(regional.par_price).to eq(par)
      expect(regional.cash).to eq(15)
    end
  end

  it 'leaves an abandoned minor (§9.5, no owner) out of it' do
    minor = start_minor!(game, 'K', president, 'RU')
    game.abandon_minor!(minor)

    expect(game.insolvent_corporations).to be_empty
  end
end
