# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# #148 part 1: until the seller can consent (part 2), a purchase from another
# player is refused (§10.4: "mutually agreed upon price"). The bank stays open.
describe 'G18OE trade protection (#148, §10.4)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game, turn: 1) }
  let(:step) { round.active_step }
  let(:player) { round.current_entity }
  let(:seller) { game.players[1] }
  let(:company) { give_company!(seller, game.company_by_id('WCF')) }
  let(:minor) { start_minor!(game, 'B', seller, 'SP') }

  it 'refuses a private from another player without consent' do
    company
    cash = player.cash

    expect(step.purchasable_companies(player)).to be_empty
    expect do
      step.process_buy_company(Engine::Action::BuyCompany.new(player, company: company, price: 0))
    end.to raise_error(Engine::GameError, /not agreed/)
    expect(company.owner).to eq(seller)
    expect(player.cash).to eq(cash)
  end

  it 'refuses a minor from another player without consent' do
    minor
    cash = player.cash

    expect(step.can_buy_corporation?(player, minor)).to be(false)
    expect(step.actions(player)).not_to include('buy_corporation')
    expect do
      step.process_buy_corporation(Engine::Action::BuyCorporation.new(player, corporation: minor, price: 0))
    end.to raise_error(Engine::GameError, /not agreed/)
    expect(minor.owner).to eq(seller)
    expect(player.cash).to eq(cash)
  end

  it 'still lets a player buy a bank-owned private at its value' do
    company.owner = game.bank
    seller.companies.delete(company)
    cash = player.cash

    step.process_buy_company(Engine::Action::BuyCompany.new(player, company: company, price: company.value))

    expect(company.owner).to eq(player)
    expect(player.cash).to eq(cash - company.value)
  end

  it 'does not enumerate purchases from another player' do
    company
    minor
    actions = Oe::LegalActions.new(game, limit: 50, rng: Random.new(1)).call

    expect(actions.grep(Engine::Action::BuyCorporation)).to be_empty
    expect(actions.grep(Engine::Action::BuyCompany).map { |a| a.company.owner }).to all(eq(game.bank))
  end
end
