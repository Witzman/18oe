# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE two-player ownership limit (PB 5.4, §10.2)' do
  include G18OESpecHelpers

  def setup_major(game)
    round = stock_round!(game)
    president = round.current_entity
    major = start_major!(game, 'LNWR', president)
    [round, round.active_step, president, major]
  end

  def hold!(game, player, corporation, percent)
    fund!(game, player)
    game.share_pool.buy_shares(player, corporation.ipo_shares.first) while player.percent_of(corporation) < percent
    expect(player.percent_of(corporation)).to eq(percent)
  end

  def to_pool!(game, corporation, count)
    game.share_pool.transfer_shares(Engine::ShareBundle.new(corporation.ipo_shares.first(count)), game.share_pool)
  end

  before { allow_any_instance_of(Engine::Game::G18OE::Game).to receive(:major_phase?).and_return(true) }

  context 'with two players' do
    let(:game) { new_game(%w[a b]) }

    it 'sets the major cap to 70 %' do
      _round, _step, _president, major = setup_major(game)

      expect([game.major_max_ownership_percent, major.max_ownership_percent]).to eq([70, 70])
    end

    it 'lets a player buy treasury shares from 60 % up to 70 %' do
      _round, step, president, major = setup_major(game)
      hold!(game, president, major, 60)

      expect(step.can_buy?(president, major.ipo_shares.first.to_bundle)).to be(true)
    end

    it 'stops a player buying beyond 70 % from the treasury' do
      _round, step, president, major = setup_major(game)
      hold!(game, president, major, 70)

      expect(step.can_buy?(president, major.ipo_shares.first.to_bundle)).to be(false)
    end

    it 'lets the president buy from the Open Market at normal price below 70 %' do
      _round, step, president, major = setup_major(game)
      hold!(game, president, major, 60)
      to_pool!(game, major, 1)
      bundle = game.share_pool.shares_of(major).first.to_bundle

      expect(step.modify_purchase_price(bundle)).to eq(bundle.price)
    end

    it 'charges the president double from the Open Market at 70 %' do
      _round, step, president, major = setup_major(game)
      hold!(game, president, major, 70)
      to_pool!(game, major, 1)
      bundle = game.share_pool.shares_of(major).first.to_bundle

      expect(step.can_gain?(president, bundle)).to be(true)
      expect(step.modify_purchase_price(bundle)).to eq(major.share_price.price * 2)
    end
  end

  context 'with three players' do
    let(:game) { new_game(%w[a b c]) }

    it 'keeps the 60 % cap' do
      _round, step, president, major = setup_major(game)
      hold!(game, president, major, 60)

      expect([game.major_max_ownership_percent, major.max_ownership_percent]).to eq([60, 60])
      expect(step.can_buy?(president, major.ipo_shares.first.to_bundle)).to be(false)
    end

    it 'charges the president double from the Open Market at 60 %' do
      _round, step, president, major = setup_major(game)
      hold!(game, president, major, 60)
      to_pool!(game, major, 1)
      bundle = game.share_pool.shares_of(major).first.to_bundle

      expect(step.modify_purchase_price(bundle)).to eq(major.share_price.price * 2)
    end
  end
end
