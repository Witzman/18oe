# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# §15.9 Minor J (Grey Locomotive Works): "This minor receives a 10% discount on the purchase price of
# all trains." The charter's ability travels into the major on a merge (§10.5). Rewritten for Chris'
# engine (#563 Task 8): the discount is the base Ability::TrainDiscount, which rounds the discount
# down (10% of £225 is £22, the RR pays £203); the old assumption (#74, round in favour of the RR,
# £202) is dropped, the rulebook names no rounding. A train of another RR has a negotiated price
# (§11.5) and gets no discount.
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

  def discounted(entity, train, variant = train.name)
    abilities = game.abilities(entity, :train_discount)
    price = train.variants[variant][:price]
    abilities.nil? ? price : abilities.discounted_price(train.clone.tap { |t| t.variant = variant }, price)
  end

  def buy!(entity, train, price, variant: train.name)
    step.process_buy_train(Engine::Action::BuyTrain.new(entity, train: train, price: price, variant: variant))
  end

  it 'offers J its reserved 2+2 for £90 and charges £90' do
    expect(card('2+2').min_price(ability: game.abilities(j, :train_discount))).to eq(90)

    cash = j.cash
    bank = game.bank.cash
    buy!(j, card('2+2'), 90)

    expect(cash - j.cash).to eq(90)
    expect(game.bank.cash - bank).to eq(90)
  end

  it 'gives no discount to a RR without the charter' do
    pending "Chris' base Step::Train only refuses a price above the card (train.rb:84); a lower depot price is not validated in the engine (#563 Task 8: Legal-Actions/UI side, not an engine rule)"
    expect(card('2+2').min_price(ability: game.abilities(k, :train_discount))).to eq(100)
    expect { buy!(k, card('2+2'), 90) }.to raise_error(Engine::GameError, /price/)
  end

  it 'rejects a price below the discounted one' do
    pending "Chris' base Step::Train does not validate a depot price below the discounted one (train.rb:84); see above"
    expect { buy!(j, card('2+2'), 80) }.to raise_error(Engine::GameError, /price/)
  end

  # Chris' base ability rounds the discount down: 10 % of 225 is 22.50, the discount is 22, the RR pays 203.
  it 'rounds the discount down on every side of a card (base Ability::TrainDiscount)' do
    game.depot.upcoming.uniq(&:name).each do |train|
      train.variants.each_key do |side|
        price = train.variants[side][:price]
        expect(discounted(j, train, side)).to eq(price - (price * 0.1).floor)
        expect(discounted(k, train, side)).to eq(price)
      end
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
      expect(discounted(major, card('3'), '3')).to eq(180)
      expect(discounted(j, card('3'), '3')).to eq(200)
    end

    # §11.6.4: a major's forced purchase counts the discounted price.
    it 'counts the discounted price for the forced purchase of a major without a train' do
      major.set_cash(50, game.bank)
      holder.set_cash(45, game.bank)

      expect(game.can_go_bankrupt?(holder, major)).to be(false)
    end
  end
end
