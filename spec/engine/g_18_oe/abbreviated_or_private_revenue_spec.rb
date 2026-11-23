# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# §13: the final two ORs are abbreviated, PB 5.3 "Long Endgame" plays them in full.

# Rewritten from legacy abbreviated_last_or_spec (#563 Task 8): Chris' game_end_spec has no example for the private
# revenue in the final ORs (rulebook 13); green on Chris' engine.
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

  # Chris' engine keeps the previous OR's run in operating_history (game_end_spec record_revenue!), not in
  # Game#record_payout!.
  def remember_payout!(corporation, revenue, kind)
    action = Engine::Action::Dividend.new(corporation, kind: kind.to_s)
    runs = corporation.trains.map { |train| Struct.new(:train, :connection_hexes, :halts, :node_signatures).new(train, [], 0, []) }
    corporation.operating_history[[3, 1]] = Engine::OperatingInfo.new(runs, action, revenue, {})
  end

  def start_round!(round_num)
    enter_round!(game, game.operating_round(round_num)).tap(&:setup)
  end

  describe 'private revenue' do
    let(:owner) { game.players.last }
    let(:private_company) { game.company_by_id('WS') }

    before do
      regional
      final_turn!(2)
      give_company!(owner, private_company)
      remember_payout!(regional, 80, :payout)
    end

    it 'is still paid to the owning player at the start of the abbreviated OR' do
      cash = owner.cash
      start_round!(2)

      expect(owner.cash - cash).to eq(private_company.revenue)
    end

    it 'is paid in the first final OR as well' do
      cash = owner.cash
      start_round!(1)

      expect(owner.cash - cash).to eq(private_company.revenue)
    end
  end
end
