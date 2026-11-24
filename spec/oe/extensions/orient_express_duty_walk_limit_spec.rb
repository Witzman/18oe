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
    seen = path_options { game.send(:duty_oe_routes, corp, game.route_trains(corp)) }

    expect(seen.map { |o| o[:walk_limit] }).to eq([Engine::Game::G18OE::OrientExpressDuty::WALK_LIMIT])
  end
end
