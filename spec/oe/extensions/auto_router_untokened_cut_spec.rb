# frozen_string_literal: true

# engine/patches/0022 (#594): Engine::AutoRouter#path cuts a walk branch at a route without the corporation's token
# the same way it cuts one with a token. Route#revenue checks the token before the distance, so a route without a
# token never raised RouteTooLong or ReusesCity and the walk from every untokened start node ran on until the map
# ran out. The router now checks such a route again without the token check and stops the branch when the route is
# too long for every train or reuses a city: no extension of it can become a valid route.
#
# The baseline is the router as it was before the patch: the second check is made to fail with NoToken, so it
# never cuts.

require_relative '../../engine/engine_helper'
require_relative '../../engine/g_18_oe/helpers'
require_relative '../../engine/upstream/lib/engine/game/g_18_oe/route_helpers'

describe 'Engine::AutoRouter#path cut at untokened routes' do
  include_context 'with 18OE route helpers'

  before do
    router_spec = self
    allow_any_instance_of(Engine::Route).to receive(:revenue).and_wrap_original do |original, **opts|
      raise Engine::NoToken, 'baseline: no cut' if router_spec.baseline && opts[:supress_route_token_check]

      original.call(**opts)
    end
  end

  attr_reader :baseline

  # [routes per train as [chains as path ids or crossing id, revenue], walk callbacks, cut by walk_limit]
  def search(corporation, trains, baseline:, **opts)
    @baseline = baseline
    callbacks = 0
    graph = game.graph_for_entity(corporation)
    allow(graph).to receive(:walk_token).and_wrap_original do |original, node, **walk_opts, &block|
      next original.call(node, **walk_opts, &block) unless walk_opts[:links]

      original.call(node, **walk_opts) do |*args|
        callbacks += 1
        block.call(*args)
      end
    end
    routes, cut = Engine::AutoRouter.new(game).path(trains, corporation, **opts)
    found = trains.to_h do |train|
      [train.id, routes[train].map { |r| [r.connection_data.map { |c| c[:chain][:id] || c[:chain][:paths].map(&:id) }, r.revenue] }]
    end
    [found, callbacks, cut]
  ensure
    @baseline = false
  end

  def expect_same_routes_fewer_callbacks(corporation, trains)
    before, before_callbacks, before_cut = search(corporation, trains, baseline: true)
    after, after_callbacks, after_cut = search(corporation, trains, baseline: false)

    expect([before_cut, after_cut]).to eq([false, false])
    expect(before.values.flatten(1)).not_to be_empty
    expect(after).to eq(before)
    expect(after_callbacks).to be < before_callbacks
  end

  context 'with the land chain Paris - Constantinople' do
    let(:major) { start_major!(game, 'LNWR', game.players[0]) }

    before do
      major
      paris_constantinople_chain!(game, major)
    end

    it 'finds the same routes in phase 2 (one 2+2) with fewer walk callbacks' do
      trains = with_trains!(game, major, '2+2')

      expect_same_routes_fewer_callbacks(major, trains)
    end

    it 'finds the same routes in phase 3 (2+2 and 3) with fewer walk callbacks' do
      trains = with_trains!(game, major, '2+2', '3')
      at_phase!(game, '3')

      expect_same_routes_fewer_callbacks(major, trains)
    end
  end

  context 'with the Baltic sea crossings and ferries' do
    let(:corp) { game.corporation_by_id('DSJ') }

    before do
      baltic!
      token!('I50', corp)
    end

    it 'finds the same routes over sea in phase 3 (one 3) with fewer walk callbacks' do
      at_phase!(game, '3')

      expect_same_routes_fewer_callbacks(corp, [buy_train!('3')])
    end

    it 'finds the same routes over sea in phase 4 (3 and 4) with fewer walk callbacks' do
      at_phase!(game, '4')

      expect_same_routes_fewer_callbacks(corp, [buy_train!('3'), buy_train!('4')])
    end
  end

  it 'is cut by walk_limit the same way every time' do
    major = start_major!(game, 'LNWR', game.players[0])
    paris_constantinople_chain!(game, major)
    trains = with_trains!(game, major, '2+2')
    first = search(major, trains, baseline: false, walk_limit: 50)

    expect(first[2]).to be(true)
    expect(search(major, trains, baseline: false, walk_limit: 50)).to eq(first)
  end
end
