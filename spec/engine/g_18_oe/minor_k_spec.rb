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

  # #508 5c (owner, 2026-11-20): of the final two ORs only the first is played normally and pays the mail
  # contract; the second is only "each RR paying again ... the same revenue" (§13, §15.10). With the long
  # endgame switch (PB 5.3) the last OR is played in full and pays like any OR.
  describe 'in the final two ORs (§13)' do
    let(:optional_rules) { [] }
    let(:game) { new_game(optional_rules: optional_rules) }

    before do
      at_phase!(game, '3')
      game.instance_variable_set(:@turn, 3)
      game.instance_variable_set(:@final_turn, 3)
      game.instance_variable_set(:@operating_rounds, 2)
    end

    it 'pays in the first, normally played OR and not in the abbreviated second one' do
      before = k.cash
      operating_round_for!(game, 1, setup: true)
      expect(k.cash - before).to eq(40)

      operating_round_for!(game, 2, setup: true)
      expect(k.cash - before).to eq(40)
    end

    it 'pays nothing from the bank in the abbreviated OR' do
      operating_round_for!(game, 1, setup: true)
      bank_cash = game.bank.cash
      operating_round_for!(game, 2, setup: true)

      expect(game.bank.cash).to eq(bank_cash)
      expect(game.log.map(&:message).grep(/mail contract/).size).to eq(1)
    end

    context 'with the long endgame switch (PB 5.3)' do
      let(:optional_rules) { [:long_endgame] }

      it 'pays in the last OR too, played in full' do
        before = k.cash
        operating_round_for!(game, 1, setup: true)
        operating_round_for!(game, 2, setup: true)

        expect(k.cash - before).to eq(80)
      end
    end
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

  # #507: §9.5 (S. 23): an abandoned minor has no operation any more and its cash goes to the bank.
  describe 'when K is abandoned (§9.5)' do
    it 'pays nothing to the abandoned charter' do
      at_phase!(game, '3')
      game.abandon_minor!(k)
      bank_before = game.bank.cash
      cash_before = k.cash
      game.pay_mail_contract!

      expect(k.cash).to eq(cash_before)
      expect(game.bank.cash).to eq(bank_before)
    end

    it 'still pays a floated K that is not abandoned' do
      at_phase!(game, '3')
      before = k.cash
      game.pay_mail_contract!

      expect(k.cash - before).to eq(40)
    end
  end
end
