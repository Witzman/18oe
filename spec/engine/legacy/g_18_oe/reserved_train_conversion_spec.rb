# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE reserved 2+2 for a regional converted before its first OR (§11.6.1)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let(:regional) { start_regional!(game, 'LNWR', player) }
  let(:round) { enter_round!(game, game.operating_round(1)) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::BuyTrain) }

  def two_plus_two
    game.depot.upcoming.find { |train| train.name == '2+2' }
  end

  def buy_reserved!(entity)
    step.process_buy_train(Engine::Action::BuyTrain.new(entity, train: two_plus_two, price: two_plus_two.price))
  end

  def convert_to_major!(corporation)
    Engine::Game::G18OE::Step::BuySellParShares.new(game, []).float_major(corporation)
    corporation
  end

  context 'when it has not bought the 2+2 yet' do
    before do
      convert_to_major!(regional)
      fund!(game, regional, 300)
      round
    end

    it 'is a major now' do
      expect(regional.type).to eq(:major)
    end

    it 'still has to buy a 2+2 from the Locomotive Works, as a major must own a train (§11.6.1)' do
      expect(step.must_buy_train?(regional)).to be(true)
      expect(game.fulfilled_train_obligation?(regional)).to be(false)
    end

    it 'may buy only the reserved 2+2 before any other train (§11.6.1)' do
      expect(step.buyable_trains(regional).map(&:name).uniq).to eq(['2+2'])
      expect(step.buyable_trains(regional).all?(&:from_depot?)).to be(true)
    end

    it 'counts the purchase as the reserved train' do
      buy_reserved!(regional)

      expect(regional.trains.map(&:name)).to eq(['2+2'])
      expect(game.fulfilled_train_obligation?(regional)).to be(true)
    end
  end

  context 'when it bought the 2+2 before converting' do
    before do
      fund!(game, regional, 300)
      round
      buy_reserved!(regional)
      convert_to_major!(regional)
    end

    it 'keeps the train and the fulfilled obligation across the conversion' do
      expect(regional.trains.map(&:name)).to eq(['2+2'])
      expect(game.fulfilled_train_obligation?(regional)).to be(true)
    end

    it 'does not have to buy another train (§11.6.1)' do
      expect(step.must_buy_train?(regional)).to be(false)
    end

    it 'is not offered a second reserved 2+2 (§11.6.1)' do
      expect(step.buyable_trains(regional).map(&:name)).not_to include('2+2')
    end
  end
end
