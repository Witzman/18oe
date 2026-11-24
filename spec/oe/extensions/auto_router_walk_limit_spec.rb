# frozen_string_literal: true

# engine/patches/0019 (#590): Engine::AutoRouter#path takes `walk_limit`, a cap on the path-walk callbacks that replaces the
# wall clock path_timeout, so the routes found do not depend on how fast the machine is.

require_relative '../../engine/engine_helper'
require_relative '../../engine/g_18_oe/helpers'

describe 'Engine::AutoRouter#path walk_limit' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:corp) do
    c = start_major!(game, 'LNWR', game.players[0])
    game.phase.next!
    game.buy_train(c, game.depot.upcoming.first, :free)
    c
  end

  def search(**opts)
    routes, cut = Engine::AutoRouter.new(game).path(game.route_trains(corp), corp, **opts)
    [routes.values.flatten.map { |r| [r.connection_data.map { |c| c[:chain][:paths].map(&:id) }, r.revenue] }, cut]
  end

  it 'finds the same routes as the clock-bound walk when the limit is not reached' do
    expected, = search
    found, cut = search(walk_limit: 10_000_000)

    expect(cut).to be(false)
    expect(found).to eq(expected)
  end

  it 'is cut after the limit, and the same way every time' do
    full, = search
    first, cut = search(walk_limit: 1)

    expect(cut).to be(true)
    expect(first.size).to be < full.size
    expect(search(walk_limit: 1)).to eq([first, true])
  end

  it 'ignores the wall clock once a walk_limit is given' do
    found, cut = search(walk_limit: 10_000_000, path_timeout: -1)

    expect(cut).to be(false)
    expect(found).not_to be_empty
  end
end
