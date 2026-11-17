# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# §11.6.6 National Trains: unclaimed rusted trains for free up to the train limit, exchange for a higher
# unclaimed rusted train, flip to the local side, upgrade with a train of a major of the same player
# (the bank pays the major half its face value).
describe 'G18OE national trains (§11.6.6)' do
  include G18OESpecHelpers

  let(:game) { at_phase!(new_game, '4') }
  let(:alice) { game.players[0] }
  let(:bob) { game.players[1] }
  let!(:lnwr) { start_major!(game, 'LNWR', alice) }
  let(:national) { lnwr.tap { |c| game.form_national!(c) } }
  let(:round) { operating_round_for!(game) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::BuyTrain) }

  def card(name)
    game.depot.upcoming.find { |t| t.name == name }
  end

  # A train of `name` that rusted with nobody claiming it: in the Locomotive Works, unclaimed.
  def unclaimed!(name, variant: nil)
    train = card(name)
    train.variant = variant if variant
    game.buy_train(lnwr, train, :free)
    game.rust(train)
    train
  end

  def owned_rusted!(corporation, name, variant: nil)
    unclaimed!(name, variant: variant).tap { |train| game.buy_train(corporation, train, :free) }
  end

  # The corporation operates and has reached its Buy Trains step (a national lays track first, #64 part d).
  def operate!(corporation)
    round.instance_variable_set(:@entity_index, round.entities.index(corporation))
    round.instance_variable_set(:@current_operator, corporation)
    round.steps.each do |s|
      break if s.is_a?(Engine::Game::G18OE::Step::BuyTrain)

      s.pass! unless s.is_a?(Engine::Game::G18OE::Step::ConvertToNational) || s.is_a?(Engine::Step::Bankrupt)
    end
  end

  def take!(train, exchange: nil)
    operate!(national)
    act!(round, Engine::Action::BuyTrain.new(national, train: train, price: 0, exchange: exchange))
  end

  describe 'claiming unclaimed rusted trains' do
    it 'takes one for free and turns it to its local side' do
      train = unclaimed!('3')
      cash = national.cash
      take!(train)

      expect(train.owner).to eq(national)
      expect(train.rusted).to be(true)
      expect(train.name).to eq('3+3')
      expect(national.cash).to eq(cash)
    end

    it 'takes them up to the train limit only' do
      4.times { unclaimed!('2+2') }
      4.times { take!(game.trains.find { |t| t.rusted && t.owner.nil? }) }
      unclaimed!('3')

      expect(national.trains.size).to eq(game.train_limit(national))
      operate!(national)
      expect(step.national_train_offers(national).none? { |train, exchange| exchange.nil? && train.owner.nil? }).to be(true)
      expect { take!(game.trains.find { |t| t.rusted && t.owner.nil? }) }.to raise_error(Engine::GameError)
    end

    it 'does not offer the trains of the Locomotive Works that have not rusted' do
      operate!(national)
      expect(step.national_train_offers(national)).to be_empty
      expect(step.actions(national)).to eq([])
    end

    it 'is free only: a price is refused' do
      train = unclaimed!('2+2')
      operate!(national)
      expect do
        act!(round, Engine::Action::BuyTrain.new(national, train: train, price: 10))
      end.to raise_error(/free|nothing/i)
    end
  end

  describe 'exchanging a rusted train' do
    it 'swaps it for a higher level unclaimed rusted train, the old one goes back unclaimed' do
      old = owned_rusted!(national, '2+2')
      higher = unclaimed!('3')
      take!(higher, exchange: old)

      expect(national.trains).to eq([higher])
      expect(higher.name).to eq('3+3')
      expect(old.owner).to be_nil
      expect(old.rusted).to be(true)
    end

    it 'refuses a train of the same or a lower level' do
      old = owned_rusted!(national, '3')
      same = unclaimed!('3')
      expect { take!(same, exchange: old) }.to raise_error(/higher/i)
    end
  end

  describe 'upgrading with a train of an own major' do
    let!(:plm) { start_major!(game, 'PLM', alice) }

    it 'takes the non-rusted train, the bank pays the major half its face value, the rusted train goes back' do
      old = owned_rusted!(national, '2+2')
      four = with_trains!(game, plm, '4').first
      plm_cash = plm.cash
      take!(four, exchange: old)

      expect(national.trains).to eq([four])
      expect(four.rusted).to be(false)
      expect(plm.trains).not_to include(four)
      expect(plm.cash - plm_cash).to eq(150)
      expect(old.owner).to be_nil
    end

    it 'rounds the half face value down' do
      old = owned_rusted!(national, '2+2')
      three = card('3')
      three.variant = '3+3'
      game.buy_train(plm, three, :free)
      plm_cash = plm.cash
      take!(three, exchange: old)

      expect(plm.cash - plm_cash).to eq(112)
      expect(three.name).to eq('3+3')
    end

    it 'needs a rusted train to give back' do
      owned_rusted!(national, '2+2')
      four = with_trains!(game, plm, '4').first
      expect { take!(four) }.to raise_error(/rusted/i)
    end

    it 'does not take a train of a major of another player' do
      gwr = start_major!(game, 'GWR', bob)
      old = owned_rusted!(national, '2+2')
      four = with_trains!(game, gwr, '4').first
      operate!(national)

      expect(step.national_train_offers(national).map(&:first)).not_to include(four)
      unclaimed!('3') # keeps the step open with another offer
      expect { take!(four, exchange: old) }.to raise_error(/cannot take/i)
    end
  end

  it 'turns the rusted trains a major keeps when it forms a national to their local side' do
    lnwr.trains.clear
    train = card('3')
    game.buy_train(lnwr, train, :free)
    game.form_national!(lnwr)
    game.send(:return_rusted_trains!, lnwr, [lnwr.trains.delete(train).tap { |t| t.rusted = true }])

    expect(train.name).to eq('3+3')
  end

  it 'offers the claims, exchanges and upgrades as actions, and a pass' do
    plm = start_major!(game, 'PLM', alice)
    old = owned_rusted!(national, '2+2')
    unclaimed!('3')
    with_trains!(game, plm, '4')
    operate!(national)

    expect(step.actions(national)).to eq(%w[buy_train pass])
    offers = step.national_train_offers(national)
    expect(offers.count { |_train, exchange| exchange.nil? }).to eq(1)
    expect(offers.count { |train, exchange| exchange == old && train.owner.nil? }).to eq(1)
    expect(offers.count { |train, exchange| exchange == old && train.owner == plm }).to eq(1)
  end
end
