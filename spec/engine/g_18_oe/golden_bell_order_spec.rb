# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# Rulebook 15.6 (p. 45): Minor C (Golden Bell Marketplace) / the major owning it chooses
# first, last or normal operating position at the start of each OR (#70).
describe 'G18OE Golden Bell operating position (§15.6)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:alice) { game.players.first }
  let(:bob) { game.players[1] }
  let!(:regionals) { %w[PLM LNWR].map { |id| start_regional!(game, id, bob) } }
  let(:minor_c) { start_minor!(game, 'C', alice, 'RU') }

  def start_or!(round_num = 1)
    enter_round!(game, game.operating_round(round_num)).tap(&:setup)
  end

  def choose!(round, player, choice)
    act!(round, Engine::Action::Choose.new(player, choice: choice))
  end

  def order(round)
    round.entities.map(&:id)
  end

  describe 'as an un-merged minor (among the regionals and minors)' do
    before { minor_c }

    it 'waits for the president before anybody operates' do
      round = start_or!

      expect(round.active_step).to be_a(Engine::Game::G18OE::Step::GoldenBellOrder)
      expect(round.current_entity).to eq(alice)
      expect(round.current_operator).to be_nil
      expect(round.active_step.choices.keys).to contain_exactly('normal', 'first', 'last')
    end

    it 'is offered by the enumerator as one choose per position' do
      round = start_or!
      actions = Oe::LegalActions.call(game)

      expect(actions.map(&:class).uniq).to eq([Engine::Action::Choose])
      expect(actions.map(&:choice)).to contain_exactly('normal', 'first', 'last')
      expect(actions.map(&:entity).uniq).to eq([alice])
      expect(round.active_step.choice_name).to include('Minor C')
    end

    it 'keeps the normal position' do
      round = start_or!
      choose!(round, alice, 'normal')

      expect(order(round)).to eq(%w[PLM LNWR C])
      expect(round.current_operator.id).to eq('PLM')
    end

    it 'operates first' do
      round = start_or!
      choose!(round, alice, 'first')

      expect(order(round)).to eq(%w[C PLM LNWR])
      expect(round.current_operator.id).to eq('C')
      expect(round.active_step).not_to be_a(Engine::Game::G18OE::Step::GoldenBellOrder)
    end

    it 'operates last among the regionals and minors, before the majors' do
      major = start_major!(game, 'GWR', bob)
      minor_c
      round = start_or!
      choose!(round, alice, 'last')

      expect(order(round)).to eq(%w[PLM LNWR C GWR])
      expect(major.floated?).to be(true)
      expect(round.current_operator.id).to eq('PLM')
    end

    it 'only counts for that OR' do
      round = start_or!
      choose!(round, alice, 'first')
      round = start_or!(2)

      expect(round.current_entity).to eq(alice)
      expect(order(round)).to eq(%w[PLM LNWR C])
      expect(game.golden_bell_position).to eq(:normal)
    end

    it 'rejects a choice by somebody else or an unknown position' do
      round = start_or!

      expect { choose!(round, bob, 'first') }.to raise_error(Engine::GameError)
      expect { choose!(round, alice, 'middle') }.to raise_error(Engine::GameError)
    end

    it 'is skipped in an abbreviated OR' do
      game.instance_variable_set(:@turn, 3)
      game.instance_variable_set(:@final_turn, 3)
      game.instance_variable_set(:@operating_rounds, 2)
      round = start_or!(2)

      expect(round.steps.map(&:class)).not_to include(Engine::Game::G18OE::Step::GoldenBellOrder)
      expect(game.golden_bell_pending?).to be(false)
    end
  end

  describe 'as a charter owned by a major (among the majors and nationals)' do
    let!(:high) { start_major!(game, 'GWR', bob).tap { |m| game.stock_market.move(m, [0, 2]) } }
    let!(:low) { start_major!(game, 'SFAI', bob).tap { |m| game.stock_market.move(m, [5, 2]) } }

    before do
      minor_c
      game.minor_regional_order.delete(minor_c)
      minor_c.spend(minor_c.cash, game.bank)
      minor_c.close!
      game.merged_minors[low] << minor_c
    end

    it 'lets the major run first among the majors' do
      round = start_or!
      choose!(round, bob, 'first')

      expect(order(round)).to eq(%w[PLM LNWR SFAI GWR])
    end

    it 'lets the high major run last' do
      game.merged_minors[low].clear
      game.merged_minors[high] << minor_c
      round = start_or!
      choose!(round, bob, 'last')

      expect(order(round)).to eq(%w[PLM LNWR SFAI GWR])
    end

    it 'keeps the share value order for normal' do
      round = start_or!
      choose!(round, bob, 'normal')

      expect(order(round)).to eq(%w[PLM LNWR GWR SFAI])
    end
  end

  it 'asks nobody when Minor C is not in play' do
    round = start_or!

    expect(game.golden_bell_pending?).to be(false)
    expect(round.active_step).not_to be_a(Engine::Game::G18OE::Step::GoldenBellOrder)
  end
end
