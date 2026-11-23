# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# §11.6.4: a major without a train must own one at the end of its OR. The president pays the
# difference from his own cash and may not sell shares; a major that cannot pay becomes a national.
describe 'G18OE forced train purchase (§11.6.4, #354)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:alice) { game.players[0] }
  let(:bob) { game.players[1] }
  let!(:lnwr) { start_major!(game, 'LNWR', alice) }
  let(:round) { at_phase!(game, '4') && operating_round_for!(game, 1) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::BuyTrain) }

  # The major operates and has reached its Buy Trains step.
  def operate!(corporation)
    round.instance_variable_set(:@entity_index, round.entities.index(corporation))
    round.instance_variable_set(:@current_operator, corporation)
    round.steps.each do |s|
      break if s.is_a?(Engine::Game::G18OE::Step::BuyTrain)

      s.pass!
    end
  end

  def buy(corporation, train, price, variant: train.name)
    Engine::Action::BuyTrain.new(corporation, train: train, price: price, variant: variant)
  end

  # Takes the cards of `name` out of the depot, so a dearer train is the cheapest one.
  def remove_from_depot!(name)
    game.depot.upcoming.reject! { |t| t.name == name }
    game.depot.depot_trains(clear: true)
  end

  def legal
    Oe::LegalActions.new(game, limit: nil).call
  end

  def cheapest
    game.depot.min_depot_train
  end

  before do
    lnwr.set_cash(80, game.bank)
    alice.set_cash(500, game.bank)
  end

  describe 'a major that has to buy and cannot pay out of its treasury' do
    before { operate!(lnwr) }

    it 'is bound to buy, and its president may not sell shares to do it' do
      expect(step.must_buy_train?(lnwr)).to be(true)
      expect(step.actions(lnwr)).to include('buy_train')
      expect(step.actions(lnwr)).not_to include('sell_shares')
      expect(step.actions(alice)).to eq([])
      expect(legal.map(&:type)).not_to include('sell_shares')
    end

    it 'has its president pay the difference from his own cash' do
      train = cheapest
      price = train.price
      act!(round, buy(lnwr, train, price))

      expect(lnwr.trains).to eq([train])
      expect(lnwr.cash).to eq(0)
      expect(alice.cash).to eq(500 - (price - 80))
    end

    it 'is not allowed to pay a dearer variant of the card out of the president\'s cash' do
      remove_from_depot!('2+2')
      expect(cheapest.name).to eq('3')

      expect { act!(round, buy(lnwr, cheapest, 225, variant: '3+3')) }.to raise_error(/cheaper train available/)
    end

    it 'takes the cheaper side of the card: the 3, not the 3+3' do
      remove_from_depot!('2+2')
      expect(game.depot.min_depot_price).to eq(200)

      act!(round, buy(lnwr, cheapest, 200))

      expect(lnwr.trains.map(&:name)).to eq(['3'])
      expect(alice.cash).to eq(500 - 120)
    end

    it 'finds the cheapest train in the Open Market too' do
      cheap = game.depot.upcoming.find { |t| t.name == '2+2' }
      remove_from_depot!('2+2')
      game.depot.discarded << cheap
      game.depot.depot_trains(clear: true)
      expect(cheapest).to eq(cheap)

      act!(round, buy(lnwr, cheap, 100))

      expect(lnwr.trains).to eq([cheap])
      expect(alice.cash).to eq(500 - 20)
    end

    it 'may buy from another railroad only with the treasury, not with the president\'s cash' do
      allow(game).to receive(:major_phase?).and_return(true)
      other = start_major!(game, 'PLM', bob)
      train = with_trains!(game, other, '2+2').first
      lnwr.set_cash(60, game.bank)

      expect { act!(round, buy(lnwr, train, 70)) }.to raise_error(Engine::GameError, /may not spend/)
      expect(alice.cash).to eq(500)

      act!(round, buy(lnwr, train, 60))

      expect(lnwr.trains).to eq([train])
      expect(lnwr.cash).to eq(0)
      expect(alice.cash).to eq(500)
    end
  end

  describe 'bankruptcy of the major is its conversion into a national (Chris: choose national, §11.6.4)' do
    before do
      lnwr.set_cash(10, game.bank)
      alice.set_cash(50, game.bank)
      operate!(lnwr)
    end

    it 'is offered when treasury and president\'s cash do not reach the cheapest train, shares ignored' do
      expect(alice.shares_of(lnwr)).not_to be_empty
      expect(game.forced_national_conversion?(lnwr)).to be(true)
      expect(step.actions(lnwr)).to include('choose')
    end

    it 'takes the private cash for the bank, turns the major into a national and the game goes on' do
      bank_before = game.bank.cash
      act!(round, Engine::Action::Choose.new(lnwr, choice: 'national'))

      expect(alice.cash).to eq(0)
      expect(game.bank.cash).to eq(bank_before + 50 + 10)
      expect(lnwr.type).to eq(:national)
      expect(alice.bankrupt).to be_falsey
      expect(game.finished).to be(false)
      expect(game.players.reject(&:bankrupt).size).to eq(game.players.size)
    end

    it 'is no longer bound to buy a train afterwards' do
      act!(round, Engine::Action::Choose.new(lnwr, choice: 'national'))

      expect(game.forced_national_conversion?(lnwr)).to be(false)
      expect(step.actions(lnwr)).to eq([])
    end
  end

  describe 'when the president can pay' do
    before { operate!(lnwr) }

    it 'does not offer bankruptcy' do
      expect(game.forced_national_conversion?(lnwr)).to be(false)
      expect(step.actions(lnwr)).not_to include('choose')
    end

    it 'refuses it when asked for anyway' do
      expect { act!(round, Engine::Action::Choose.new(lnwr, choice: 'national')) }.to raise_error(Engine::GameError)
      expect(lnwr.type).to eq(:major)
    end
  end

  it 'never lets a corporation that need not buy go bankrupt' do
    with_trains!(game, lnwr, '2+2')
    lnwr.set_cash(0, game.bank)
    alice.set_cash(0, game.bank)

    expect(game.forced_national_conversion?(lnwr)).to be(false)
    expect(game.can_go_bankrupt?(alice, lnwr)).to be(false)
  end
end
