# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #55 part 2: buying and discarding a Pullman in the Buy Trains step (§11.6, §11.6.2, §15.9, §15.12),
# as `choose` actions of the step. `buyer` (PLM) operates; LNWR is the seller or the one M merged into.
describe 'G18OE buying a Pullman (§11.6.2)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let!(:lnwr) { start_major!(game, 'LNWR', game.players.first) }
  let!(:buyer) { start_major!(game, 'PLM', game.players.last) }
  let(:m) { game.corporation_by_id('M') }
  let(:round) { at_phase!(game, '4') && operating_round_for!(game, 1) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::BuyTrain) }

  before do
    [lnwr, buyer].each do |corporation|
      with_trains!(game, corporation, '2+2')
      game.fulfill_train_obligation!(corporation)
      corporation.set_cash(400, game.bank)
    end
    round.instance_variable_set(:@entity_index, round.entities.index(buyer))
    round.instance_variable_set(:@current_operator, buyer)
  end

  def choose!(choice)
    step.process_choose(Engine::Action::Choose.new(buyer, choice: choice))
  end

  it 'offers no purchase before the Pullman event' do
    expect(step.pullman_choices(buyer)).to eq({})
  end

  context 'after the event' do
    before { game.event_pullmans_available! }

    it 'buys from Minor M for £150; the bank pays £15 royalty to the major M merged into' do
      game.merged_minors[lnwr] << m
      expect(step.pullman_choices(buyer)).to include('pullman_m')
      lnwr_cash = lnwr.cash
      expect { choose!('pullman_m') }.to change(buyer, :cash).by(-150)
      expect(lnwr.cash).to eq(lnwr_cash + 15)
      expect(game.pullman?(buyer)).to be(true)
      expect(game.pullman_supply).to eq(8)
    end

    it 'applies Minor J\'s 10% to the price but not to the royalty (§15.9)' do
      game.merged_minors[lnwr] << m
      game.add_minor_charter!(game.corporation_by_id('J'), buyer)
      lnwr_cash = lnwr.cash
      expect { choose!('pullman_m') }.to change(buyer, :cash).by(-135)
      expect(lnwr.cash).to eq(lnwr_cash + 15)
    end

    it 'buys from the Open Market for £150 without royalty' do
      game.instance_variable_set(:@pullman_market, 1)
      lnwr_cash = lnwr.cash
      expect(step.pullman_choices(buyer)).to include('pullman_market')
      expect { choose!('pullman_market') }.to change(buyer, :cash).by(-150)
      expect(game.pullman_market).to eq(0)
      expect(lnwr.cash).to eq(lnwr_cash)
    end

    it 'buys from another RR for exactly £75' do
      game.receive_pullman!(lnwr)
      expect(step.pullman_choices(buyer)).to include("pullman_from:#{lnwr.id}")
      lnwr_cash = lnwr.cash
      expect { choose!("pullman_from:#{lnwr.id}") }.to change(buyer, :cash).by(-75)
      expect(lnwr.cash).to eq(lnwr_cash + 75)
      expect(game.pullman?(buyer)).to be(true)
      expect(game.pullman?(lnwr)).to be(false)
    end

    it 'offers no second Pullman to a RR that owns one (§11.6.2)' do
      game.receive_pullman!(buyer)
      expect(step.pullman_choices(buyer).keys.grep(/\Apullman_(m|market|from)/)).to be_empty
    end

    it 'offers nothing the treasury cannot pay' do
      buyer.set_cash(100, game.bank)
      game.instance_variable_set(:@pullman_market, 1)
      expect(step.pullman_choices(buyer)).to eq({})
    end

    it 'discards a Pullman to the Open Market without refund before buying a train' do
      game.receive_pullman!(buyer)
      expect(step.pullman_choices(buyer)).to include('pullman_discard')
      expect { choose!('pullman_discard') }.not_to(change(buyer, :cash))
      expect(game.pullman?(buyer)).to be(false)
      expect(game.pullman_market).to eq(1)
    end

    it 'rejects a choice that is not on offer' do
      expect { choose!('pullman_market') }.to raise_error(Engine::GameError, /Pullman/)
    end
  end
end

describe 'Pullman choices are no bot move yet (#55)' do
  it 'is recognised by the strategy player' do
    require 'oe/strategy_player'
    choose = Engine::Action::Choose.new(nil, choice: 'pullman_market')
    expect(Oe::StrategyPlayer.pullman_choice?(choose)).to be(true)
    expect(Oe::StrategyPlayer.pullman_choice?(Engine::Action::Choose.new(nil, choice: 'merge_offer'))).to be(false)
  end
end
