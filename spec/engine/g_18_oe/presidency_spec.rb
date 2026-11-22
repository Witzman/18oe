# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE change of presidency (§10.3)' do
  include G18OESpecHelpers

  let(:game) { new_game(%w[a b c d]) }
  let(:round) { stock_round!(game) }
  let(:a) { game.players[0] }
  let(:b) { game.players[1] }
  let(:c) { game.players[2] }
  let(:d) { game.players[3] }
  let(:president) { a }
  # the president presides over LNWR with 30% (the 20% president's certificate and one 10% share)
  let(:major) do
    start_major!(game, 'LNWR', president).tap { |corporation| take_treasury_shares!(game, president, corporation, 1) }
  end

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    round
    major
  end

  def percent(player)
    player.percent_of(major)
  end

  def sell_one!(player)
    pass_until!(round, player)
    share = player.shares_of(major).reject(&:president).first
    act!(round, Engine::Action::SellShares.new(player, shares: [share], percent: share.percent))
  end

  def buyable_bundles(player)
    game.bundles_for_corporation(player, major).select { |bundle| round.active_step.can_sell?(player, bundle) }
  end

  it 'makes a player with more shares than the president the new president (§10.3)' do
    take_treasury_shares!(game, b, major, 4)

    expect([major.owner, major.presidents_share.owner]).to eq([b, b])
  end

  it 'swaps the 20% certificate for two 10% certificates with the old president (§10.3)' do
    take_treasury_shares!(game, b, major, 4)

    expect([percent(a), percent(b)]).to eq([30, 40])
    expect(a.shares_of(major).map(&:percent).sort).to eq([10, 10, 10])
    expect(b.shares_of(major).map(&:percent).sort).to eq([10, 10, 20])
  end

  it 'keeps the old president when another player only equals their percentage (§10.3 "more shares")' do
    take_treasury_shares!(game, b, major, 3)

    expect([percent(a), percent(b), major.owner]).to eq([30, 30, a])
  end

  it 'changes the presidency when the president sells below another player (§10.3)' do
    take_treasury_shares!(game, b, major, 3)
    sell_one!(a)

    expect([percent(a), major.owner]).to eq([20, b])
    expect(b.shares_of(major).map(&:percent).sort).to eq([10, 20])
    expect(a.shares_of(major).map(&:percent).sort).to eq([10, 10])
  end

  describe 'equal claims of two other players (§10.3)' do
    before do
      take_treasury_shares!(game, c, major, 3)
      take_treasury_shares!(game, d, major, 3)
    end

    it 'gives the presidency to the tied player closest to the left of the old president' do
      sell_one!(a)

      expect([percent(c), percent(d), major.owner]).to eq([30, 30, c])
    end
  end

  describe 'equal claims across the end of the table (§10.3)' do
    let(:president) { d }

    it 'wraps around from the last player to the first (the player to the left of d is a)' do
      take_treasury_shares!(game, a, major, 3)
      take_treasury_shares!(game, b, major, 3)
      sell_one!(d)

      expect([percent(a), percent(b), percent(d)]).to eq([30, 30, 20])
      expect(major.owner).to eq(a)
    end
  end

  describe 'the 20% obligation (§10.3)' do
    it 'forbids selling the 20% certificate while no other player holds 20%' do
      expect(buyable_bundles(a).map(&:percent)).to eq([10])
      expect(buyable_bundles(a).any?(&:presidents_share)).to be(false)
    end

    it 'allows the 20% certificate once another player holds 20% (§10.3)' do
      take_treasury_shares!(game, b, major, 2)

      expect(buyable_bundles(a).any?(&:presidents_share)).to be(true)
    end

    it 'does not allow the president to sell the certificate when the Open Market would pass 50% (§10.1, §10.3)' do
      take_treasury_shares!(game, b, major, 2)
      game.share_pool.transfer_shares(Engine::ShareBundle.new(major.ipo_shares.first(4)), game.share_pool)

      expect(game.share_pool.percent_of(major)).to eq(40)
      expect(buyable_bundles(a).map(&:percent)).to eq([10])
    end
  end
end
