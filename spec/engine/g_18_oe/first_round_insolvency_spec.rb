# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE first-round insolvency (§11.6.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:president) { game.players.first }
  let(:minor) { start_minor!(game, 'K', president, 'RU') }
  let(:round) do
    minor
    enter_round!(game, game.operating_round(1))
  end
  let(:step) { round_step(round, Engine::Game::G18OE::Step::BuyTrain) }

  def reach_buy_train!
    round.skip_steps until round.active_step.is_a?(Engine::Game::G18OE::Step::BuyTrain) || round.active_step.nil?
  end

  context 'when the president cannot make up the difference' do
    before do
      minor.set_cash(30, game.bank)
      president.set_cash(40, game.bank)
    end

    it 'is insolvent, and offers no action instead of a dead end' do
      expect(step.first_round_insolvency?(minor)).to be(true)
      expect(step.actions(minor)).to eq([])
    end

    it 'gives the minor its 2+2, the president\'s cash and moves the charter to the Open Market' do
      bank_before = game.bank.cash
      step.skip!

      expect(minor.trains.map(&:name)).to eq(['2+2'])
      expect(minor.cash).to eq(70)
      expect(president.cash).to eq(120)
      expect(game.bank.cash).to eq(bank_before - 120)
      expect(minor.owner).to eq(game.share_pool)
      expect(minor.receivership?).to be(true)
      expect(game.fulfilled_train_obligation?(minor)).to be(true)
      expect(game.share_pool.shares_by_corporation[minor]).to include(minor.presidents_share)
    end

    it 'lets nobody operate the minor until it is owned again' do
      step.skip!

      expect(round.skip_entity?(minor)).to be(true)
    end
  end

  it 'leaves a solvent minor alone (the president contributes)' do
    minor.set_cash(30, game.bank)
    president.set_cash(80, game.bank)

    expect(step.first_round_insolvency?(minor)).to be(false)
    expect(step.actions(minor)).to include('buy_train')
  end

  it 'pays a regional president 2 x par for the president\'s certificate' do
    regional = start_regional!(game, 'LNWR', president, par: 60)
    enter_round!(game, game.operating_round(1))
    step = round_step(game.round, Engine::Game::G18OE::Step::BuyTrain)
    regional.set_cash(10, game.bank)
    president.set_cash(5, game.bank)
    step.skip!

    expect(president.cash).to eq(120)
    expect(regional.cash).to eq(15)
    expect(regional.owner).to eq(game.share_pool)
    expect(regional.trains.map(&:name)).to eq(['2+2'])
  end
end
