# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'
require 'oe/bot'
require 'oe/view'

# §10.4 (#202): "A player may purchase minors or face up privates from another player at a mutually
# agreed upon price." The buyer's buy_company / buy_corporation is an offer; the seller answers at once
# (choose 'accept_trade' or pass = decline), only an accepted offer moves anything. Owner decision F1
# (2026-11-18, workshop #67): trading is a stock action in every stock round, not only the opening one.
describe 'G18OE trade offer between players (§10.4, #202)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game, turn: 1) }
  let(:player) { round.current_entity }
  let(:seller) { game.players[1] }
  let(:company) { give_company!(seller, game.company_by_id('WCF')) }
  let(:minor) { start_minor!(game, 'B', seller, 'SP') }

  def offer_company!(target, price, buyer = player)
    act!(round, Engine::Action::BuyCompany.new(buyer, company: target, price: price))
  end

  def offer_minor!(target, price, buyer = player)
    act!(round, Engine::Action::BuyCorporation.new(buyer, corporation: target, price: price))
  end

  def accept!(by = seller)
    act!(round, Engine::Action::Choose.new(by, choice: 'accept_trade'))
  end

  def decline!(by = seller)
    act!(round, Engine::Action::Pass.new(by))
  end

  it 'is switched on' do
    expect(game.player_trade_enabled?).to be(true)
  end

  it 'turns a purchase from another player into an offer the seller must answer; nothing moves yet' do
    company
    buyer_cash = player.cash
    seller_cash = seller.cash

    offer_company!(company, 35)

    expect(company.owner).to eq(seller)
    expect([player.cash, seller.cash]).to eq([buyer_cash, seller_cash])
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::TradeOffer)
    expect(round.active_step.active_entities).to eq([seller])
    expect(round.active_step.actions(seller)).to eq(%w[choose pass])
    expect(round.active_step.actions(player)).to be_empty
    expect(round.active_step.choices).to eq('accept_trade' => 'Accept')
    expect(round.active_step.choice_name).to include(player.name, company.name, '35')
    expect(game.log.map(&:message).last).to include('offers', company.name, seller.name)
  end

  it 'executes the trade when the seller accepts and ends the buyer\'s turn' do
    company
    buyer = player
    buyer_cash = buyer.cash
    seller_cash = seller.cash

    offer_company!(company, 35)
    accept!

    expect(company.owner).to eq(buyer)
    expect(buyer.cash).to eq(buyer_cash - 35)
    expect(seller.cash).to eq(seller_cash + 35)
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::BuySellParShares)
    expect(round.current_entity).to eq(seller)
    expect(round.last_to_act).to eq(buyer)
  end

  it 'moves nothing when the seller declines; the buyer keeps the turn and may act again' do
    company
    buyer = player
    state = [buyer.cash, seller.cash]

    offer_company!(company, 35)
    decline!

    expect(company.owner).to eq(seller)
    expect([buyer.cash, seller.cash]).to eq(state)
    expect(round.current_entity).to eq(buyer)
    expect(round.current_actions).to be_empty
    expect(round.active_step.actions(buyer)).to include('buy_company')
    expect(game.log.map(&:message).last).to include('declines')
  end

  it 'trades a floated minor with its presidency on acceptance and not on a decline' do
    minor
    buyer = player

    offer_minor!(minor, 80)
    expect(minor.owner).to eq(seller)
    decline!
    expect(minor.owner).to eq(seller)

    offer_minor!(minor, 90)
    accept!
    expect(minor.owner).to eq(buyer)
    expect(buyer.percent_of(minor)).to eq(100)
  end

  it 'allows trading in a later stock round, not only in the opening one (owner decision F1, #67)' do
    later = stock_round!(game, turn: 3)
    company
    minor
    buyer = later.current_entity
    step = later.active_step

    expect(step.actions(buyer)).to include('buy_company', 'buy_corporation')
    act!(later, Engine::Action::BuyCompany.new(buyer, company: company, price: 20))
    act!(later, Engine::Action::Choose.new(seller, choice: 'accept_trade'))

    expect(company.owner).to eq(buyer)
  end

  it 'allows trading once the Major Railroad Phase has begun (F1)' do
    at_phase!(game, '3')
    later = stock_round!(game, turn: 2)
    minor

    expect(later.active_step.can_buy_corporation?(later.current_entity, minor)).to be(true)
  end

  it 'offers no trade in a consolidation round, which is not a stock round (§10.6)' do
    allow(game).to receive(:major_phase?).and_return(true)
    game.instance_variable_set(:@turn, 2)
    start_regional!(game, 'LNWR', game.players[0])
    minor
    game.phase.next!
    consolidation = enter_round!(game, game.new_consolidation_round)
    buy_step = consolidation.steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::BuySellParShares) }

    expect(buy_step.can_buy_corporation?(game.players[0], minor)).to be(false)
    expect do
      buy_step.process_buy_corporation(Engine::Action::BuyCorporation.new(game.players[0], corporation: minor, price: 5))
    end.to raise_error(Engine::GameError)
    expect(minor.owner).to eq(seller)
  end

  it 'refuses an offer above the buyer\'s cash; no offer is made' do
    company
    price = player.cash + 1

    expect { offer_company!(company, price) }.to raise_error(RuntimeError, /Price must be/)
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::BuySellParShares)
    expect(company.owner).to eq(seller)
  end

  it 'checks the buyer\'s cash again when the seller accepts' do
    company
    offer_company!(company, 35)
    player.spend(player.cash - 10, game.bank)

    expect { accept! }.to raise_error(RuntimeError, /cash/)
    expect(company.owner).to eq(seller)
  end

  # The offer is part of the buyer's stock action (RB §10: one stock action per turn); there are no
  # standing offers. It blocks until the seller answers, so it can never outlive the turn or the round.
  it 'blocks the round until the seller answers; the offer never outlives the buyer\'s turn' do
    company
    buyer = player
    offer_company!(company, 35)

    expect { act!(round, Engine::Action::Pass.new(buyer)) }.to raise_error(RuntimeError)
    expect(round.current_entity).to eq(seller)
    expect(round.active_step.pending_offer.entity).to eq(buyer)
    decline!
    expect(round.current_entity).to eq(buyer)
    expect(round.steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::TradeOffer) }).not_to be_active
  end

  it 'rejects an answer by anyone but the seller' do
    company
    offer_company!(company, 35)
    third = game.players[2]

    expect { act!(round, Engine::Action::Choose.new(third, choice: 'accept_trade')) }.to raise_error(RuntimeError)
    expect(company.owner).to eq(seller)
  end

  it 'enumerates the offer for the buyer and accept/decline for the seller' do
    round
    company
    offers = Oe::LegalActions.new(game, limit: 5, rng: Random.new(1)).call
    expect(offers.grep(Engine::Action::BuyCompany).map(&:company)).to include(company)

    offer_company!(company, 35)
    answers = Oe::LegalActions.new(game, limit: 5, rng: Random.new(1)).call
    expect(answers.map { |a| [a.class, a.entity] })
      .to contain_exactly([Engine::Action::Choose, seller], [Engine::Action::Pass, seller])
  end

  it 'describes trade offers as price ranges in compact mode instead of one action per price' do
    round
    company
    minor
    legal = Oe::LegalActions.new(game, compact: true)
    actions = legal.call

    expect(actions.grep(Engine::Action::BuyCompany).map(&:company)).not_to include(company)
    expect(actions.grep(Engine::Action::BuyCorporation)).to be_empty
    expect(legal.ranges).to include(
      { type: 'buy_company', entity: player.id, company: company.id, min: 0, max: player.cash, step: 1 },
      { type: 'buy_corporation', entity: player.id, company: minor.id, min: 0, max: player.cash, step: 1 },
    )
  end

  it 'shows the open offer in the view: context.trade for everyone, accept/decline for the seller' do
    round
    company
    buyer = player
    offer_company!(company, 35)

    seller_view = Oe::View.render(game, viewer: seller.id, log: 0)[:prompt]
    buyer_view = Oe::View.render(game, viewer: buyer.id, log: 0)[:prompt]

    trade = { buyer: buyer.id, seller: seller.id, kind: 'company', target: company.id, price: 35, give: [], also: [] }
    expect(seller_view[:step]).to eq('TradeOffer')
    expect(seller_view[:context][:trade]).to eq(trade)
    expect(seller_view[:choices].map { |c| c[:choice] }).to eq(['accept_trade'])
    expect(seller_view[:pass_description]).to eq('Decline')
    expect(seller_view[:actions].map { |a| a['type'] }).to contain_exactly('choose', 'pass')
    expect(buyer_view[:viewer_to_act]).to be(false)
    expect(buyer_view[:context][:trade]).to eq(trade)
  end

  it 'lets a bot seller decline and makes no offers as a bot buyer' do
    round
    company
    bot = Oe::Bot.new(game, rng: Random.new(3))
    expect(bot.legal_actions(player.id).grep(Engine::Action::BuyCompany).map(&:company)).not_to include(company)

    offer_company!(company, 35)
    answer = bot.choose(player_id: seller.id)

    expect(answer).to be_a(Engine::Action::Pass)
    expect(answer.entity).to eq(seller)
  end
end
