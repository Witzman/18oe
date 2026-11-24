# frozen_string_literal: true

# engine/patches/0020 (#593): the Orient Express duty check (patch 0012) searches with a walk_limit, not the wall clock,
# so whether a RR is obliged to run the Orient Express does not depend on how fast the machine is.

require_relative '../../engine/engine_helper'
require_relative '../../engine/g_18_oe/helpers'

describe 'Orient Express duty search walk_limit' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:corp) do
    c = start_major!(game, 'LNWR', game.players[0])
    game.phase.next!
    game.buy_train(c, game.depot.upcoming.first, :free)
    c
  end

  def path_options
    seen = []
    allow_any_instance_of(Engine::AutoRouter).to receive(:path).and_wrap_original do |orig, *args, **opts|
      seen << opts
      orig.call(*args, **opts)
    end
    yield
    seen
  end

  it 'passes the shared walk limit when it searches the routes of the trains' do
    seen = path_options { game.send(:duty_train_routes, corp) }

    expect(seen.map { |o| o[:walk_limit] }).to eq([Engine::Game::G18OE::OrientExpressDuty::WALK_LIMIT])
  end

  it 'passes the shared walk limit when it searches a combined train' do
    seen = path_options { game.orient_express_trial_routes(corp, game.route_trains(corp)) }

    expect(seen.map { |o| o[:walk_limit] }).to eq([Engine::Game::G18OE::OrientExpressDuty::WALK_LIMIT])
  end
end

# engine/patches/0025 (#600): a combined-train search is made once per game state. generate_double_head_trains,
# the duty check and every combination asked the same question (same RR, same summed reach) and each walk of the
# whole network took 5-8 s on a late map.
describe 'Orient Express combined-train search memo' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:corp) do
    c = start_major!(game, 'LNWR', game.players[0])
    game.phase.next!
    game.buy_train(c, game.depot.upcoming.first, :free)
    c
  end

  def searches
    count = 0
    allow_any_instance_of(Engine::AutoRouter).to receive(:path).and_wrap_original do |orig, *args, **opts|
      count += 1
      orig.call(*args, **opts)
    end
    yield
    count
  end

  it 'walks the network once for the same combined train in the same state' do
    trains = game.route_trains(corp)
    first = nil
    again = nil
    count = searches do
      first = game.orient_express_trial_routes(corp, trains)
      again = game.orient_express_trial_routes(corp, trains)
    end

    expect(count).to eq(1)
    expect(again).to equal(first)
  end

  it 'walks again in the next state' do
    trains = game.route_trains(corp)
    game.orient_express_trial_routes(corp, trains)
    game.instance_variable_set(:@last_processed_action, :other)

    expect(searches { game.orient_express_trial_routes(corp, trains) }).to eq(1)
  end
end
