# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE minor K, Vermilion Seal mail contract (§15.10)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let!(:k) { start_minor!(game, 'K', player, 'SP') }
  let(:treasury_before) { k.cash }

  # §15.10: the bank pays at the beginning of each OR: Phase 2 £20, 3-4 £40, 5-6 £50, 7-8 £60.
  { '2' => 20, '3' => 40, '4' => 40, '5' => 50, '6' => 50, '7' => 60, '8' => 60 }.each do |phase, amount|
    it "pays £#{amount} to the treasury at the start of an OR in Phase #{phase}" do
      at_phase!(game, phase)
      before = k.cash
      operating_round_for!(game, 1, setup: true)

      expect(k.cash - before).to eq(amount)
    end
  end

  it 'takes the money from the bank' do
    before = game.bank.cash
    operating_round_for!(game, 1, setup: true)

    expect(before - game.bank.cash).to eq(20)
  end

  it 'pays before the first RR operates (§15.10)' do
    operating_round_for!(game, 1, setup: true)
    messages = game.log.map(&:message)

    expect(messages.index('K receives mail contract of £20')).to be < messages.index('a operates K')
  end

  it 'pays again at the start of every OR' do
    operating_round_for!(game, 1, setup: true)
    operating_round_for!(game, 2, setup: true)

    expect(k.cash).to eq(160)
  end

  it 'logs the payment' do
    operating_round_for!(game, 1, setup: true)

    expect(game.log.map(&:message)).to include(a_string_matching(/\AK receives mail contract of £20\z/))
  end

  it 'pays nothing while K is not started' do
    other = new_game
    before = other.bank.cash
    operating_round_for!(other, 1, setup: true)

    expect(other.bank.cash).to eq(before)
  end

  describe 'when merged into a major (§10.5)' do
    let(:round) { stock_round!(game) }
    let(:holder) { round.current_entity }
    let(:major) { start_major!(game, 'LNWR', holder) }
    let(:minor) { game.corporation_by_id('K') }

    before do
      allow(game).to receive(:major_phase?).and_return(true)
      game.phase.next!
      major
      act!(round, Engine::Action::Choose.new(round.current_entity, choice: minor.id))
      act!(round, Engine::Action::Merge.new(minor, corporation: major))
    end

    it 'pays the major instead, and not the closed minor' do
      major_before = major.cash
      minor_before = minor.cash
      operating_round_for!(game, 1, setup: true)

      expect(major.cash - major_before).to eq(40)
      expect(minor.cash).to eq(minor_before)
    end
  end
end
