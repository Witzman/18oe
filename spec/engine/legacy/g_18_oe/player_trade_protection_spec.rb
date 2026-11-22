# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# #148 part 1 refused a purchase from another player until the seller could consent (§10.4: "mutually
# agreed upon price"). With part 2 (#202) the seller consents in Step::TradeOffer, so the protection now
# reads: without the seller's acceptance nothing moves; the switch can still turn player trading off.
# Changed with #202 (the examples used to expect a GameError "not agreed" for every purchase).
describe 'G18OE trade protection (#148, #202, §10.4)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game, turn: 1) }
  let(:step) { round.active_step }
  let(:player) { round.current_entity }
  let(:seller) { game.players[1] }
  let(:company) { give_company!(seller, game.company_by_id('WCF')) }
  let(:minor) { start_minor!(game, 'B', seller, 'SP') }

  it 'moves no private from another player without the seller\'s consent' do
    company
    cash = player.cash

    step.process_buy_company(Engine::Action::BuyCompany.new(player, company: company, price: 0))

    expect(company.owner).to eq(seller)
    expect(player.cash).to eq(cash)
    expect(round.steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::TradeOffer) }).to be_active
  end

  it 'moves no minor from another player without the seller\'s consent' do
    minor
    cash = player.cash

    step.process_buy_corporation(Engine::Action::BuyCorporation.new(player, corporation: minor, price: 0))

    expect(minor.owner).to eq(seller)
    expect(player.cash).to eq(cash)
    expect(round.steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::TradeOffer) }).to be_active
  end

  it 'refuses every purchase from another player while the switch is off' do
    allow(game).to receive(:player_trade_enabled?).and_return(false)
    company
    minor

    expect(step.purchasable_companies(player)).to be_empty
    expect(step.actions(player)).not_to include('buy_corporation')
    expect do
      step.process_buy_company(Engine::Action::BuyCompany.new(player, company: company, price: 0))
    end.to raise_error(Engine::GameError, /not agreed/)
    expect do
      step.process_buy_corporation(Engine::Action::BuyCorporation.new(player, corporation: minor, price: 0))
    end.to raise_error(Engine::GameError, /not agreed/)
  end

  it 'still lets a player buy a bank-owned private at its value, without an offer' do
    company.owner = game.bank
    seller.companies.delete(company)
    cash = player.cash

    step.process_buy_company(Engine::Action::BuyCompany.new(player, company: company, price: company.value))

    expect(company.owner).to eq(player)
    expect(player.cash).to eq(cash - company.value)
  end

  it 'enumerates purchases from another player only while the switch is on' do
    round
    company
    minor
    on = Oe::LegalActions.new(game, limit: 50, rng: Random.new(1)).call
    allow(game).to receive(:player_trade_enabled?).and_return(false)
    off = Oe::LegalActions.new(game, limit: 50, rng: Random.new(1)).call

    expect(on.grep(Engine::Action::BuyCorporation).map(&:corporation)).to include(minor)
    expect(on.grep(Engine::Action::BuyCompany).map(&:company)).to include(company)
    expect(off.grep(Engine::Action::BuyCorporation)).to be_empty
    expect(off.grep(Engine::Action::BuyCompany).map { |a| a.company.owner }).to all(eq(game.bank))
  end
end
