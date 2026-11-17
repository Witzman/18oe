# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# §15.9 Minor J (Grey Locomotive Works): "This minor receives a 10% discount on the purchase price of
# all trains." The charter's ability travels into the major on a merge (§10.5). ASSUMPTION (workshop
# #74): fractions go in favour of the RR as for construction discounts (§11.1.3: "Round fractions in
# favor of the RR"), so the discount of a 3+3 (£225) is £23 and it costs £202. A train of another RR
# has a negotiated price (§11.5) and gets no discount.
describe 'G18OE minor J, Grey Locomotive Works (§15.9)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let!(:j) { start_minor!(game, 'J', player, 'SP') }
  let!(:k) { start_minor!(game, 'K', game.players[1], 'RU') }
  let(:round) { enter_round!(game, game.operating_round(1)) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::BuyTrain) }

  def card(name)
    game.depot.upcoming.find { |t| t.name == name }
  end

  def offers(entity)
    allow(step).to receive(:current_entity).and_return(entity)
    Oe::LegalActions.new(game).send(:generate_buy_train, step, entity)
  end

  def buy!(entity, train, price, variant: train.name)
    step.process_buy_train(Engine::Action::BuyTrain.new(entity, train: train, price: price, variant: variant))
  end

  it 'offers J its reserved 2+2 for £90 and charges £90' do
    expect(offers(j).map(&:price).uniq).to eq([90])

    cash = j.cash
    bank = game.bank.cash
    buy!(j, card('2+2'), 90)

    expect(cash - j.cash).to eq(90)
    expect(game.bank.cash - bank).to eq(90)
  end

  it 'gives no discount to a RR without the charter' do
    expect(offers(k).map(&:price).uniq).to eq([100])
    expect { buy!(k, card('2+2'), 90) }.to raise_error(Engine::GameError, /price/)
  end

  it 'rejects a price below the discounted one' do
    expect { buy!(j, card('2+2'), 80) }.to raise_error(Engine::GameError, /price/)
  end

  # Fractions in favour of the RR: 10 % of 225 is 22.50, the RR pays 202.
  {
    %w[2+2 2+2] => 90, %w[3 3] => 180, %w[3 3+3] => 202, %w[4 4+4] => 315, %w[5 5+5] => 427,
    %w[6 6] => 472, %w[6 6+6] => 540, %w[7+7 4D] => 765, %w[8+8 5D] => 900
  }.each do |(card_name, side), price|
    it "prices the #{side} side at £#{price}" do
      expect(step.depot_price(j, card(card_name), side)).to eq(price)
      expect(step.depot_price(k, card(card_name), side)).to eq(card(card_name).variants[side][:price])
    end
  end

  it 'lets J buy for less than the face value when its treasury is short' do
    j.set_cash(95, game.bank)

    expect(step.can_buy_train?(j)).to be(true)
  end

  describe 'when merged into a major (§10.5)' do
    let(:sr) { stock_round!(game) }
    let(:holder) { sr.current_entity }
    let(:major) { start_major!(game, 'LNWR', holder) }

    before do
      allow(game).to receive(:major_phase?).and_return(true)
      game.phase.next!
      major
      act!(sr, Engine::Action::Choose.new(sr.current_entity, choice: j.id))
      act!(sr, Engine::Action::Merge.new(j, corporation: major))
    end

    it 'gives the discount to the major' do
      expect(step.depot_price(major, card('3'), '3')).to eq(180)
      expect(step.depot_price(j, card('3'), '3')).to eq(200)
    end

    # §11.6.4: a major's forced purchase counts the discounted price.
    it 'counts the discounted price for the forced purchase of a major without a train' do
      major.set_cash(50, game.bank)
      holder.set_cash(45, game.bank)

      expect(game.can_go_bankrupt?(holder, major)).to be(false)
    end
  end
end
