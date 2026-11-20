# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'
require 'oe/bot'
require 'oe/view'

# §10.4 (#517): "The players may only exchange personal cash, minors and face up privates during this
# transaction." The offer of #202 gets objects on both sides: `give` (the buyer's own minors/face up
# privates) and `also` (more of the seller's), next to the target and the price in cash.
describe 'G18OE trade offer with objects on both sides (§10.4, #517)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game, turn: 1) }
  let(:buyer) { round.current_entity }
  let(:seller) { game.players[1] }
  let(:their_private) { give_company!(seller, game.company_by_id('WCF')) }
  let(:my_private) { give_company!(buyer, game.company_by_id('SHTC')) }
  let(:their_minor) { start_minor!(game, 'B', seller, 'SP') }
  let(:my_minor) { start_minor!(game, 'C', buyer, 'RU') }

  def offer!(target, price: 0, give: [], also: [])
    action = if target.corporation?
               Engine::Action::BuyCorporation.new(buyer, corporation: target, price: price, give: give, also: also)
             else
               Engine::Action::BuyCompany.new(buyer, company: target, price: price, give: give, also: also)
             end
    act!(round, action)
  end

  def accept!
    act!(round, Engine::Action::Choose.new(seller, choice: 'accept_trade'))
  end

  it 'swaps a private for a private and moves no cash at price 0' do
    their_private
    my_private
    cash = [buyer.cash, seller.cash]

    offer!(their_private, give: [my_private])
    expect([their_private.owner, my_private.owner]).to eq([seller, buyer])
    accept!

    expect([their_private.owner, my_private.owner]).to eq([buyer, seller])
    expect(buyer.companies).to include(their_private)
    expect(buyer.companies).not_to include(my_private)
    expect(seller.companies).to include(my_private)
    expect([buyer.cash, seller.cash]).to eq(cash)
    expect(round.current_entity).to eq(seller)
  end

  it 'swaps a minor against a private plus cash' do
    their_private
    my_minor

    offer!(their_private, price: 25, give: [my_minor])
    cash = [buyer.cash, seller.cash]
    accept!

    expect(my_minor.owner).to eq(seller)
    expect(seller.percent_of(my_minor)).to eq(100)
    expect(buyer.percent_of(my_minor)).to eq(0)
    expect(their_private.owner).to eq(buyer)
    expect([buyer.cash, seller.cash]).to eq([cash[0] - 25, cash[1] + 25])
  end

  it 'swaps a private for a minor and takes several of the seller\'s objects' do
    their_minor
    their_private
    my_private

    offer!(their_minor, give: [my_private], also: [their_private])
    accept!

    expect(their_minor.owner).to eq(buyer)
    expect(their_private.owner).to eq(buyer)
    expect(my_private.owner).to eq(seller)
  end

  it 'moves nothing when the seller declines' do
    their_private
    my_private
    offer!(their_private, give: [my_private])
    act!(round, Engine::Action::Pass.new(seller))

    expect([their_private.owner, my_private.owner]).to eq([seller, buyer])
    expect(round.current_entity).to eq(buyer)
  end

  it 'refuses what is not tradable: face down privates, merged minors, objects of the wrong owner' do
    their_private
    my_private
    game.flip_private!(my_private)
    expect { offer!(their_private, give: [my_private]) }.to raise_error(RuntimeError, /face down|Cannot trade/)

    other = give_company!(game.players[2], game.company_by_id('HMLC'))
    expect { offer!(their_private, give: [other]) }.to raise_error(RuntimeError, /yours|Cannot trade/)
    expect { offer!(their_private, also: [other]) }.to raise_error(RuntimeError, /Cannot trade|seller/)
    expect { offer!(their_private, give: [their_private]) }.to raise_error(RuntimeError)
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::BuySellParShares)

    allow(game).to receive(:merged_minors).and_return({ 'X' => [my_minor] })
    expect { offer!(their_private, give: [my_minor]) }.to raise_error(RuntimeError, /Cannot trade/)
  end

  it 'checks the certificate limit of both sides after the exchange (§4.1)' do
    their_private
    my_private
    their_minor
    # seller would hold one more certificate (private + minor offered for one private)
    limit = game.num_certs(seller)
    allow(game).to receive(:cert_limit) { |player| player == seller ? limit : 99 }
    expect { offer!(their_private, give: [my_private, my_minor]) }.to raise_error(RuntimeError, /certificate limit/)
  end

  it 'keeps the plain cash offer unchanged: no give, no also' do
    their_private
    offer!(their_private, price: 35)
    accept!
    expect(their_private.owner).to eq(buyer)
  end

  it 'serializes the objects only when there are some, so old logs are unchanged' do
    their_private
    my_private
    plain = Engine::Action::BuyCompany.new(buyer, company: their_private, price: 5)
    swap = Engine::Action::BuyCompany.new(buyer, company: their_private, price: 5, give: [my_private])

    expect(plain.to_h.keys).not_to include('give', 'also')
    back = Engine::Action::Base.action_from_h(swap.to_h, game)
    expect(back.give).to eq([my_private])
    expect(back.also).to eq([])
  end

  it 'tells the seller what is offered in the log and the view' do
    their_private
    my_minor
    offer!(their_private, price: 10, give: [my_minor])

    expect(game.log.map(&:message).last).to include(my_minor.name, their_private.name)
    trade = Oe::View.render(game, viewer: seller.id, log: 0)[:prompt][:context][:trade]
    expect(trade).to include(target: their_private.id, price: 10,
                             give: [{ kind: 'corporation', id: my_minor.id }], also: [])
  end

  it 'enumerates swap offers for the buyer and still only accept/decline for the seller' do
    their_private
    my_private
    offers = Oe::LegalActions.new(game, limit: 200, rng: Random.new(1)).call
    swaps = offers.grep(Engine::Action::BuyCompany).select { |a| a.give.any? }

    expect(swaps).not_to be_empty
    expect(swaps.map(&:give).flatten.uniq).to eq([my_private])
    offer!(their_private, give: [my_private])
    answers = Oe::LegalActions.new(game, limit: 5, rng: Random.new(1)).call
    expect(answers.map { |a| [a.class, a.entity] })
      .to contain_exactly([Engine::Action::Choose, seller], [Engine::Action::Pass, seller])
  end
end
