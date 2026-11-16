# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# §13: the final two ORs are abbreviated, PB 5.3 "Long Endgame" plays them in full.
describe 'G18OE abbreviated last OR (§13)' do
  include G18OESpecHelpers

  let(:optional_rules) { [] }
  let(:game) { new_game(optional_rules: optional_rules) }
  let(:president) { game.players.first }
  let(:regional) do
    operating_regional!(game, 'LNWR', president)
  end

  def final_turn!(operating_rounds)
    game.instance_variable_set(:@turn, 3)
    game.instance_variable_set(:@final_turn, 3)
    game.instance_variable_set(:@operating_rounds, operating_rounds)
  end

  def step_classes(round)
    round.steps.map { |step| step.class.name.split('::').last }.grep_v(/EndGame|Message|Program/)
  end

  def remember_payout!(corporation, revenue, kind)
    game.record_payout!(corporation, revenue, kind)
  end

  def start_round!(round_num)
    enter_round!(game, game.operating_round(round_num)).tap(&:setup)
  end

  describe 'which OR is abbreviated' do
    it 'is the second final OR of a two-OR final set' do
      final_turn!(2)

      expect([1, 2].map { |n| game.abbreviated_or?(n) }).to eq([false, true])
    end

    it 'is only the third OR of an extended three-OR final set' do
      final_turn!(3)

      expect([1, 2, 3].map { |n| game.abbreviated_or?(n) }).to eq([false, false, true])
    end

    it 'is no OR before the final turn' do
      game.instance_variable_set(:@turn, 2)
      game.instance_variable_set(:@final_turn, 3)
      game.instance_variable_set(:@operating_rounds, 2)

      expect(game.abbreviated_or?(2)).to be(false)
    end

    it 'is no OR while the game end is not triggered' do
      expect(game.abbreviated_or?(2)).to be(false)
    end

    context 'with the long endgame switch (PB 5.3)' do
      let(:optional_rules) { [:long_endgame] }

      it 'plays every final OR in full' do
        final_turn!(2)

        expect(game.abbreviated_or?(2)).to be(false)
        expect(step_classes(game.operating_round(2))).to include('Track', 'Token', 'BuyTrain', 'IssueShares')
      end
    end
  end

  it 'has no track laying, token placement, train buying or share issue in the abbreviated OR' do
    final_turn!(2)

    expect(step_classes(game.operating_round(2))).to eq(%w[Route Dividend OrientExpressBonus])
    expect(step_classes(game.operating_round(1))).to include('Track', 'Token', 'BuyTrain')
  end

  describe 'repeating the payout' do
    before do
      regional
      final_turn!(2)
      game.bank.spend(1000, president)
    end

    it 'pays the previous revenue again without any action when the trains are unchanged' do
      remember_payout!(regional, 80, :payout)
      cash = president.cash
      round = start_round!(2)

      expect(round.finished?).to be(true)
      expect(president.cash).to be > cash
      expect(game.log.map(&:message)).to include(a_string_matching(/LNWR pays out .*80/))
    end

    it 'withholds again when the previous OR withheld' do
      remember_payout!(regional, 80, :withhold)
      treasury = regional.cash
      cash = president.cash
      start_round!(2)

      expect([regional.cash - treasury, president.cash]).to eq([80, cash])
    end

    it 'asks for a new run and payout once the railroad got another train' do
      remember_payout!(regional, 80, :payout)
      game.buy_train(regional, game.depot.upcoming.first, :free)
      round = start_round!(2)

      expect(round.active_step).to be_a(Engine::Game::G18OE::Step::Route)
    end

    it 'asks for a new run when a train was lost since the previous OR' do
      remember_payout!(regional, 80, :payout)
      game.remove_train(regional.trains.first)
      regional.trains.shift
      cash = president.cash
      start_round!(2)

      expect(president.cash).to eq(cash)
    end

    it 'does not repeat in a full OR (long endgame)' do
      game.instance_variable_set(:@final_turn, nil)
      remember_payout!(regional, 80, :payout)

      expect(game.repeated_payout(regional, game.operating_round(2))).to be_nil
    end
  end

  it 'enters the abbreviated OR from the first final OR and ends the game after it' do
    regional
    final_turn!(2)
    remember_payout!(regional, 80, :payout)
    enter_round!(game, game.operating_round(1))

    game.next_round!

    expect(step_classes(game.round)).to eq(%w[Route Dividend OrientExpressBonus])
    expect(game.send(:end_now?, :one_more_full_or_set)).to be(true)
  end

  describe 'bank break interplay' do
    before do
      regional
      final_turn!(2)
    end

    it 'ends the game after the first final OR when the bank breaks in it, so the abbreviated OR is skipped' do
      game.instance_variable_set(:@round, game.operating_round(1))
      game.bank.spend(game.bank.cash + 1, president)

      expect(game.send(:end_now?, :current_or)).to be(true)
    end
  end
end
