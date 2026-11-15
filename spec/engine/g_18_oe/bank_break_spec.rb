# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE a broken bank ends the game after one OR (§13)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:regional) do
    start_regional!(game, 'LNWR', game.players.first).tap do |corporation|
      game.buy_train(corporation, game.depot.upcoming.first, :free)
      game.fulfill_train_obligation!(corporation)
    end
  end

  def break_bank!
    game.bank.spend(game.bank.cash + 1, game.players.last)
  end

  def operating_rounds_started
    game.log.map(&:message).grep(/\A-- Operating Round/)
  end

  # Plays the single regional through one OR without running, so the round ends on its own.
  def play_operating_round!(round_num)
    while !game.finished && game.round.operating? && game.round.round_num == round_num
      entity = game.round.active_step.current_entity
      actions = game.round.active_step.actions(entity)
      action = if actions.include?('run_routes')
                 Engine::Action::RunRoutes.new(entity, routes: [])
               elsif actions.include?('dividend')
                 Engine::Action::Dividend.new(entity, kind: 'withhold')
               else
                 Engine::Action::Pass.new(entity)
               end
      act!(game, action)
    end
  end

  def pass_stock_round!
    act!(game, Engine::Action::Pass.new(game.round.current_entity)) while !game.finished && game.round.stock?
  end

  before do
    regional
    allow(game).to receive(:major_phase?).and_return(false)
  end

  it 'is not broken by normal play and plays both ORs of the set (control)' do
    stock_round!(game)
    pass_stock_round!
    play_operating_round!(1)

    expect(game.finished).to be(false)
    expect(game.round.round_num).to eq(2)
  end

  it 'keeps paying after it ran empty, the bank cash going negative like the remainder cash used as needed (§13)' do
    break_bank!
    before = game.bank.cash

    expect { game.bank.spend(100, game.players.first) }.not_to raise_error
    expect([game.bank.broken?, game.bank.cash]).to eq([true, before - 100])
  end

  it 'finishes only the current OR when the bank breaks during an OR (§13)' do
    enter_round!(game, game.operating_round(1))
    break_bank!
    play_operating_round!(1)

    expect(game.finished).to be(true)
    expect(operating_rounds_started.size).to eq(0)
    expect(game.log.map(&:message).last).to match(/Game over/)
  end

  it 'plays one more OR when the bank breaks during a stock round (§13)' do
    stock_round!(game)
    break_bank!
    pass_stock_round!

    expect(game.finished).to be(false)
    expect(game.round.operating?).to be(true)

    play_operating_round!(1)

    expect(game.finished).to be(true)
    expect(operating_rounds_started.size).to eq(1)
  end

  it 'does not play the second OR of the set after a break in the stock round (§13 "one more OR")' do
    stock_round!(game)
    break_bank!
    pass_stock_round!
    play_operating_round!(1)

    expect(game.round.round_num).to eq(1)
    expect(game.log.map(&:message)).not_to include(a_string_matching(/Operating Round \d+\.2/))
  end
end
