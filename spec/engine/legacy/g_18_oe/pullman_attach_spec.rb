# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #55: the president says which train carries the Pullman (§11.3.9); without a choice it is the highest
# level train. The choice is a `choose` of the run trains step.
describe 'G18OE attaching the Pullman to a train (§11.3.9)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let!(:lnwr) { start_major!(game, 'LNWR', game.players.first) }
  let(:round) { at_phase!(game, '4') && operating_round_for!(game, 1) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::Route) }
  let!(:trains) { with_trains!(game, lnwr, '2+2', '3') }
  let(:low) { trains.first }
  let(:high) { trains.last }

  before do
    game.fulfill_train_obligation!(lnwr)
    game.receive_pullman!(lnwr)
    round.instance_variable_set(:@entity_index, round.entities.index(lnwr))
    round.instance_variable_set(:@current_operator, lnwr)
  end

  def route_for(train)
    instance_double(Engine::Route, corporation: lnwr, train: train)
  end

  it 'attaches to the highest level train by default' do
    expect(game.pullman_train(lnwr)).to eq(high)
  end

  it 'offers every other train as a choice of the run trains step' do
    expect(step.pullman_choices(lnwr).keys).to eq(["pullman_on:#{low.id}"])
    expect(step.actions(lnwr)).to include('choose')
  end

  it 'moves the bonus to the chosen train' do
    step.process_choose(Engine::Action::Choose.new(lnwr, choice: "pullman_on:#{low.id}"))
    expect(game.pullman_train(lnwr)).to eq(low)
    expect(game.pullman_revenue(route_for(low))).to eq(20)
    expect(game.pullman_revenue(route_for(high))).to eq(0)
  end

  it 'offers the highest train back after a choice of the lower one' do
    step.process_choose(Engine::Action::Choose.new(lnwr, choice: "pullman_on:#{low.id}"))
    expect(step.pullman_choices(lnwr).keys).to eq(["pullman_on:#{high.id}"])
  end

  it 'falls back to the highest train when the chosen one is gone' do
    step.process_choose(Engine::Action::Choose.new(lnwr, choice: "pullman_on:#{low.id}"))
    game.remove_train(low)
    lnwr.trains.delete(low)
    expect(game.pullman_train(lnwr)).to eq(high)
  end

  it 'rejects a train the RR does not own' do
    expect { step.process_choose(Engine::Action::Choose.new(lnwr, choice: 'pullman_on:nope')) }
      .to raise_error(Engine::GameError, /Pullman/)
  end

  it 'offers no choice with a single train or no Pullman' do
    game.pullman_owners.delete(lnwr)
    expect(step.pullman_choices(lnwr)).to eq({})
  end
end
