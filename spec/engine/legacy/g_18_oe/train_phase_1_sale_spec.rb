# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE no stock sales during Train Phase 1 (§10.1)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:turn) { 1 }
  let(:round) { stock_round!(game, turn: turn) }
  let(:player) { round.current_entity }
  let(:major) { start_major!(game, 'LNWR', player) }

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    take_treasury_shares!(game, player, major, 1)
  end

  def sellable?
    round.active_step.can_sell?(player, player.shares_of(major).reject(&:president).first.to_bundle)
  end

  it 'counts the first stock round as turn 1 and the stock round after the first OR set as turn 2 (§5.2)' do
    fresh = new_game
    enter_round!(fresh, fresh.stock_round)
    expect(fresh.turn).to eq(1)

    fresh.next_round!
    expect([fresh.round.operating?, fresh.turn]).to eq([true, 1])

    fresh.next_round! until fresh.round.stock?
    expect(fresh.turn).to eq(2)
  end

  it 'refuses a sale in the first stock round, the one of Train Phase 1 (§10.1)' do
    expect(sellable?).to be(false)
  end

  it 'offers no sell action in the first stock round' do
    expect(round.active_step.actions(player)).not_to include('sell_shares')
  end

  context 'after the first operating round set' do
    let(:turn) { 2 }

    it 'allows the same sale from the second stock round on (§10.1)' do
      expect(sellable?).to be(true)
    end

    it 'offers the sell action again' do
      expect(round.active_step.actions(player)).to include('sell_shares')
    end
  end
end
