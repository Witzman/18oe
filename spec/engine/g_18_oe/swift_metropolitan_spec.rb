# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# #83 (§14.10, §11.6, §12.1): Swift Metropolitan Line preserves one rusted 2+2 for the owner's RR.
describe 'G18OE Swift Metropolitan Line (§14.10)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:owner) { game.players[0] }
  let(:other) { game.players[1] }
  let(:sml) { give_company!(owner, game.company_by_id('SML')) }
  let(:operator) { start_major!(game, 'LNWR', owner) }

  # The rusted pool: 2+2 cards that rusted and belong to nobody (§11.6.6).
  def rust_two_plus_twos!(count = 2)
    game.depot.upcoming.select { |t| t.name == '2+2' }.first(count).each do |train|
      game.remove_train(train)
      train.rusted = true
      train.owner = nil
    end
  end

  def round_for(phase)
    sml
    operator
    at_phase!(game, phase)
    rust_two_plus_twos!
    operating_round_for!(game, 1, setup: true)
  end

  def assign_action(corporation = operator)
    Engine::Action::Choose.new(sml, choice: 'sml_train', target: corporation)
  end

  def offered
    Oe::LegalActions.new(game).call.select { |a| a.is_a?(Engine::Action::Choose) && a.entity == sml }
  end

  it 'offers nothing before Train Phase 4' do
    round_for('3')

    expect(offered).to be_empty
  end

  it 'offers the owner an assignment to the operating RR from Train Phase 4' do
    round_for('4')

    expect(offered.map(&:target)).to eq([operator])
  end

  it 'offers nothing when no rusted 2+2 is left' do
    round_for('4')
    game.unclaimed_rusted_trains.each { |t| t.rusted = false }

    expect(offered).to be_empty
  end

  it 'offers nothing for a RR of another player' do
    sml
    foreign = start_major!(game, 'LNWR', other)
    at_phase!(game, '4')
    rust_two_plus_twos!
    game.minor_regional_order.unshift(foreign)
    operating_round_for!(game, 1, setup: true)

    expect(offered).to be_empty
  end

  it 'gives the RR a rusted 2+2 that does not count against its train limit' do
    round = round_for('4')
    limit_used = game.num_corp_trains(operator)

    act!(round, assign_action)

    train = game.sml_train
    expect(train.name).to eq('2+2')
    expect(operator.trains).to include(train)
    expect(game.num_corp_trains(operator)).to eq(limit_used)
    expect(game.face_down_private?(sml)).to be(true)
  end

  it 'is used once' do
    round = round_for('4')
    act!(round, assign_action)

    expect(offered).to be_empty
  end

  it 'does not fulfil the train obligation of the RR' do
    round = round_for('4')
    operator.trains.dup.each { |t| game.remove_train(t) }
    act!(round, assign_action)

    step = Engine::Game::G18OE::Step::BuyTrain.new(game, [])
    expect(operator.trains).to eq([game.sml_train])
    expect(step.must_buy_train?(operator)).to be(true)
  end

  it 'can never be bought from the RR by another one' do
    round = round_for('4')
    act!(round, assign_action)
    buyer = start_regional!(game, 'PLM', owner)
    step = round_step(round, Engine::Game::G18OE::Step::BuyTrain)
    # a rusted train is not `buyable` upstream either; the step also drops it should a depot offer it
    allow(game.depot).to receive(:other_trains).and_return([game.sml_train])

    expect(step.buyable_trains(buyer)).not_to include(game.sml_train)
  end

  it 'is not offered to the discard of a crowded RR' do
    round = round_for('4')
    act!(round, assign_action)
    step = Engine::Game::G18OE::Step::DiscardTrain.new(game, [])

    expect(step.trains(operator)).not_to include(game.sml_train)
  end

  it 'is no candidate for an Orient Express combination' do
    round = round_for('4')
    act!(round, assign_action)

    expect(game.double_head_candidates(operator)).not_to include(game.sml_train)
  end

  it 'refuses a train the owner does not control' do
    round = round_for('4')

    expect { act!(round, assign_action(start_regional!(game, 'PLM', other))) }.to raise_error(Engine::GameError, /cannot/)
  end

  it 'runs although it has rusted (the RR runs it when its other trains are gone)' do
    round = round_for('4')
    act!(round, assign_action)

    expect(game.route_trains(operator)).to include(game.sml_train)
  end
end
