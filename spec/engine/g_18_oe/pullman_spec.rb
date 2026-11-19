# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #55 part 1: ownership and revenue of Pullman cars (§11.6.2, §11.3.9, §12.1, §15.12).
describe 'G18OE Pullman cars (§11.6.2)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let(:m) { game.corporation_by_id('M') }
  let!(:lnwr) { start_major!(game, 'LNWR', player) }

  it 'comes with the first 4 train' do
    four = game.depot.upcoming.find { |t| t.name == '4' }
    expect(four.events).to eq([{ 'type' => 'pullmans_available' }])
  end

  it 'gives Minor M a free Pullman when the event fires, nine stay to be bought' do
    game.event_pullmans_available!
    expect(game.pullman?(m)).to be(true)
    expect(game.pullman_supply).to eq(9)
  end

  it 'gives the free Pullman to the major Minor M merged into' do
    game.merged_minors[lnwr] << m
    game.event_pullmans_available!
    expect(game.pullman?(lnwr)).to be(true)
    expect(game.pullman?(m)).to be(false)
  end

  it 'moves the Pullman of M to the major on a merge (§11.6.2)' do
    game.event_pullmans_available!
    game.add_minor_charter!(m, lnwr)
    expect(game.pullman?(lnwr)).to be(true)
    expect(game.pullman?(m)).to be(false)
  end

  it 'discards one to the Open Market when both own one (§11.6.2)' do
    game.event_pullmans_available!
    game.receive_pullman!(lnwr)
    game.add_minor_charter!(m, lnwr)
    expect(game.pullman?(lnwr)).to be(true)
    expect(game.pullman_market).to eq(1)
  end

  it 'sends the Pullman of a major to the Open Market when it forms a national (§9.4)' do
    game.receive_pullman!(lnwr)
    game.form_national!(lnwr)
    expect(game.pullman?(lnwr)).to be(false)
    expect(game.pullman_market).to eq(1)
  end

  it 'owns at most one: a second goes to the Open Market' do
    2.times { game.receive_pullman!(lnwr) }
    expect(game.pullman_market).to eq(1)
  end

  describe 'revenue' do
    let(:trains) { with_trains!(game, lnwr, '2+2', '3') }

    it 'attaches to the highest level train: £10 per level' do
      trains
      game.receive_pullman!(lnwr)
      expect(game.pullman_train(lnwr).name).to eq('3')
      route = instance_double(Engine::Route, corporation: lnwr, train: game.pullman_train(lnwr))
      expect(game.pullman_revenue(route)).to eq(30)
    end

    it 'adds nothing for another train or without a Pullman' do
      low, high = trains
      route = instance_double(Engine::Route, corporation: lnwr, train: high)
      expect(game.pullman_revenue(route)).to eq(0)
      game.receive_pullman!(lnwr)
      expect(game.pullman_revenue(instance_double(Engine::Route, corporation: lnwr, train: low))).to eq(0)
    end

    it 'counts the level of one sub-train of a combined train, not the sum (§12.1)' do
      low, high = trains
      combined = instance_double(Engine::Train, sym: '5')
      round = double('round', combined_trains: { combined => [low, high] })
      allow(game).to receive(:round).and_return(round)
      game.instance_variable_set(:@round, round)
      expect(game.pullman_train_level(combined)).to eq(3)
    end
  end
end
